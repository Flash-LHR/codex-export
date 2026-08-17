import Foundation

/// Transport seam used by the client. Production uses a local stdio process;
/// tests can inject an in-memory implementation without launching Codex.
protocol LineRPCTransport: Sendable {
    func start() async throws
    func send(request: Data, id: Int) async throws -> Data
    func notify(_ notification: Data) async throws
    func shutdown() async
}

enum CodexBinaryLocator {
    static let environmentKey = "CODEX_EXPORT_CODEX_PATH"

    static func findBinary() -> URL? {
        findBinary(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func findBinary(
        environment: [String: String],
        homeDirectory: URL,
        systemCandidates: [String] = defaultSystemCandidates,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[environmentKey],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        return candidatePaths(
            environment: environment,
            homeDirectory: homeDirectory,
            systemCandidates: systemCandidates
        )
        .first(where: fileManager.isExecutableFile(atPath:))
        .map(URL.init(fileURLWithPath:))
    }

    static func candidatePaths(
        environment: [String: String],
        homeDirectory: URL,
        systemCandidates: [String] = defaultSystemCandidates
    ) -> [String] {
        var paths = systemCandidates
        paths.append(contentsOf: [
            homeDirectory.appendingPathComponent(
                ".codex/packages/standalone/current/bin/codex"
            ).path,
            homeDirectory.appendingPathComponent(
                ".codex/packages/standalone/current/codex"
            ).path,
            homeDirectory.appendingPathComponent(".local/bin/codex").path,
        ])
        paths.append(contentsOf: (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path })

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static let defaultSystemCandidates = [
        "/Applications/ChatGPT.app/Contents/Resources/codex",
        "/Applications/Codex.app/Contents/Resources/codex",
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
    ]
}

/// Converts arbitrarily-sized stdout chunks into complete JSONL records.
///
/// FileHandle may invoke its readability handler again before an unstructured
/// task created by an earlier invocation runs. Reading and framing under one
/// lock preserves the pipe's byte order before anything crosses an actor hop.
final class OrderedLineFramer: @unchecked Sendable {
    private let lock = NSLock()
    private var partialLine = Data()

    func readAvailable(from handle: FileHandle) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return appendUnlocked(handle.availableData)
    }

    func append(_ data: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return appendUnlocked(data)
    }

    private func appendUnlocked(_ data: Data) -> [Data] {
        guard !data.isEmpty else { return [] }

        var lines: [Data] = []
        var segmentStart = data.startIndex
        while segmentStart < data.endIndex,
              let newline = data[segmentStart...].firstIndex(of: 0x0A) {
            if partialLine.isEmpty {
                lines.append(Data(data[segmentStart..<newline]))
            } else {
                partialLine.append(contentsOf: data[segmentStart..<newline])
                lines.append(partialLine)
                partialLine = Data()
            }
            segmentStart = data.index(after: newline)
        }
        if segmentStart < data.endIndex {
            partialLine.append(contentsOf: data[segmentStart...])
        }
        return lines
    }
}

actor StdioLineRPCTransport: LineRPCTransport {
    private struct PendingRequest {
        let continuation: CheckedContinuation<Data, Error>
        let timeoutTask: Task<Void, Never>
    }

    private let binaryURL: URL
    private let timeoutNanoseconds: UInt64
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var errorHandle: FileHandle?
    private var pending: [Int: PendingRequest] = [:]
    private var generation = 0

    init(binaryURL: URL, timeout: TimeInterval) {
        self.binaryURL = binaryURL
        self.timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
    }

    deinit {
        process?.terminationHandler = nil
        outputHandle?.readabilityHandler = nil
        errorHandle?.readabilityHandler = nil
        process?.terminate()
    }

    func start() async throws {
        if process?.isRunning == true { return }
        shutDownCurrentProcess()

        generation += 1
        let currentGeneration = generation
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let standardError = Pipe()
        process.executableURL = binaryURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = standardError
        let outputFramer = OrderedLineFramer()
        process.terminationHandler = { [weak self] _ in
            Task { await self?.handleTermination(generation: currentGeneration) }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let lines = outputFramer.readAvailable(from: handle)
            guard !lines.isEmpty else { return }
            Task { await self?.consume(lines, generation: currentGeneration) }
        }
        standardError.fileHandleForReading.readabilityHandler = { handle in
            // Drain stderr so the child cannot block, but never log transcript data.
            _ = handle.availableData
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            output.fileHandleForReading.readabilityHandler = nil
            standardError.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        self.process = process
        inputHandle = input.fileHandleForWriting
        outputHandle = output.fileHandleForReading
        errorHandle = standardError.fileHandleForReading
    }

    func send(request: Data, id: Int) async throws -> Data {
        guard process?.isRunning == true, let inputHandle else {
            throw AppServerClientError.processUnavailable
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
                    guard !Task.isCancelled else { return }
                    await self?.expire(id: id)
                }
                pending[id] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask
                )
                do {
                    var line = request
                    line.append(0x0A)
                    try inputHandle.write(contentsOf: line)
                } catch {
                    finish(id: id, result: .failure(AppServerClientError.processUnavailable))
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    func notify(_ notification: Data) async throws {
        guard process?.isRunning == true, let inputHandle else {
            throw AppServerClientError.processUnavailable
        }
        do {
            var line = notification
            line.append(0x0A)
            try inputHandle.write(contentsOf: line)
        } catch {
            throw AppServerClientError.processUnavailable
        }
    }

    func shutdown() async {
        shutDownCurrentProcess()
    }

    private func shutDownCurrentProcess() {
        generation += 1
        let activeProcess = process
        let input = inputHandle
        let output = outputHandle
        let error = errorHandle
        activeProcess?.terminationHandler = nil
        output?.readabilityHandler = nil
        error?.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        errorHandle = nil
        failAll(with: AppServerClientError.processUnavailable)
        if activeProcess?.isRunning == true { activeProcess?.terminate() }
        try? input?.close()
        try? output?.close()
        try? error?.close()
    }

    private func consume(_ lines: [Data], generation: Int) {
        guard generation == self.generation else { return }
        for line in lines {
            handle(line: line)
        }
    }

    private func handle(line: Data) {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: line),
              let dictionary = object as? [String: Any],
              let id = numericID(dictionary["id"]) else {
            // Notifications and server-initiated requests are not conversation data.
            return
        }
        finish(id: id, result: .success(line))
    }

    private func numericID(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double { return Int(value) }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private func expire(id: Int) {
        finish(id: id, result: .failure(AppServerClientError.requestTimedOut))
    }

    private func cancel(id: Int) {
        finish(id: id, result: .failure(CancellationError()))
    }

    private func finish(id: Int, result: Result<Data, Error>) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeoutTask.cancel()
        request.continuation.resume(with: result)
    }

    private func failAll(with error: Error) {
        let requests = pending.values
        pending.removeAll()
        for request in requests {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }

    private func handleTermination(generation: Int) async {
        guard generation == self.generation else { return }
        shutDownCurrentProcess()
    }
}
