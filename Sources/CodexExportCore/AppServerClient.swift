import Foundation

public enum AppServerClientError: LocalizedError, Sendable {
    case codexBinaryNotFound
    case processUnavailable
    case requestTimedOut
    case fastPaginationUnavailable
    case invalidResponse
    case rpcError(code: Int?)

    public var errorDescription: String? {
        switch self {
        case .codexBinaryNotFound:
            return "没有找到 Codex，请确认 Codex App 已安装。"
        case .processUnavailable:
            return "无法连接本机 Codex，请稍后重试。"
        case .requestTimedOut:
            return "读取任务超时，请重试。"
        case .fastPaginationUnavailable:
            return "当前 Codex 版本不支持快速读取，请更新 Codex 后重试。"
        case .invalidResponse:
            return "Codex 返回了无法识别的数据。"
        case .rpcError:
            return "Codex 无法完成这次读取。"
        }
    }
}

public actor CodexAppServerClient {
    private struct ExperimentalMethodUnavailable: Error, Sendable {}

    private struct InitializationAttempt {
        let generation: UInt64
        let task: Task<Void, Error>
    }

    private struct ShutdownAttempt {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    public struct Configuration: Sendable {
        public let clientVersion: String
        public let maximumTaskCount: Int
        public let pageSize: Int
        public let messagePageSize: Int
        public let requestTimeout: TimeInterval

        public init(
            clientVersion: String = "development",
            maximumTaskCount: Int = 10,
            pageSize: Int = 10,
            messagePageSize: Int = 12,
            requestTimeout: TimeInterval = 60
        ) {
            let trimmedVersion = clientVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            self.clientVersion = trimmedVersion.isEmpty
                ? "development"
                : trimmedVersion
            self.maximumTaskCount = max(1, maximumTaskCount)
            self.pageSize = min(100, max(1, pageSize))
            self.messagePageSize = min(100, max(1, messagePageSize))
            self.requestTimeout = max(1, requestTimeout)
        }
    }

    private struct RPCEnvelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: RPCError?
    }

    private struct RPCError: Decodable {
        let code: Int?
        let message: String
    }

    private struct InitializeResult: Decodable {}

    private let configuration: Configuration
    private let transportFactory: @Sendable () throws -> any LineRPCTransport
    private var transport: (any LineRPCTransport)?
    private var initialized = false
    private var connectionGeneration: UInt64 = 0
    private var initializationAttempt: InitializationAttempt?
    private var shutdownAttempt: ShutdownAttempt?
    private var nextID = 1

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.transportFactory = {
            guard let binaryURL = CodexBinaryLocator.findBinary() else {
                throw AppServerClientError.codexBinaryNotFound
            }
            return StdioLineRPCTransport(
                binaryURL: binaryURL,
                timeout: configuration.requestTimeout
            )
        }
    }

    init(
        transport: any LineRPCTransport,
        configuration: Configuration = Configuration()
    ) {
        self.transport = transport
        self.configuration = configuration
        self.transportFactory = { transport }
    }

    public func listTasks() async throws -> [TaskSummary] {
        try await withReconnectRetry {
            try await self.listTasksOnce()
        }
    }

    /// Lists one fixed-size page of active tasks for the history browser.
    public func listTaskPage(
        cursor: String? = nil,
        limit: Int = 30
    ) async throws -> TaskSummaryPage {
        try await withReconnectRetry {
            try await self.listTaskPageOnce(
                cursor: cursor,
                limit: limit
            )
        }
    }

    /// Reads the lightweight local task-title index used by the first search
    /// stage. The UI applies its own case-insensitive matching to the same
    /// sanitized titles it displays, rather than relying on App Server's raw
    /// extracted-title filter.
    public func listTaskTitleIndex() async throws -> [TaskSummary] {
        try await withReconnectRetry {
            try await self.listTaskTitleIndexOnce()
        }
    }

    /// Searches conversation text after title matches have been presented.
    /// Older App Server builds without thread/search return an empty page; the
    /// already completed title search remains available without a duplicate
    /// fallback request.
    public func searchTaskContentPage(
        cursor: String? = nil,
        searchTerm: String,
        limit: Int = 30
    ) async throws -> TaskSummaryPage {
        try await withReconnectRetry {
            try await self.searchTaskContentPageOnce(
                cursor: cursor,
                searchTerm: searchTerm,
                limit: limit
            )
        }
    }

    private func listTaskTitleIndexOnce() async throws -> [TaskSummary] {
        try await ensureInitialized()
        var cursor: String?
        var seenCursors = Set<String>()
        var seenTaskIDs = Set<String>()
        var tasks: [TaskSummary] = []

        repeat {
            try Task.checkCancellation()
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw AppServerClientError.invalidResponse
            }
            let page = try await listTaskPageUsingThreadList(
                cursor: cursor,
                limit: 100
            )
            try Task.checkCancellation()
            for task in page.tasks where seenTaskIDs.insert(task.id).inserted {
                tasks.append(task)
            }
            if let cursor, page.nextCursor == cursor {
                throw AppServerClientError.invalidResponse
            }
            cursor = page.nextCursor
            await Task.yield()
        } while cursor != nil

        return tasks
    }

    private func searchTaskContentPageOnce(
        cursor: String?,
        searchTerm: String,
        limit: Int
    ) async throws -> TaskSummaryPage {
        try await ensureInitialized()
        let query = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return TaskSummaryPage(tasks: [], nextCursor: nil)
        }

        var params: [String: Any] = [
            "searchTerm": query,
            "limit": min(100, max(1, limit)),
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "archived": false,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        do {
            let page: ThreadSearchPage = try await request(
                method: "thread/search",
                params: params
            )
            return TaskSummaryPage(
                tasks: page.data.map {
                    TranscriptNormalizer.taskSummary(from: $0.thread)
                },
                nextCursor: normalizedCursor(page.nextCursor)
            )
        } catch is ExperimentalMethodUnavailable {
            return TaskSummaryPage(tasks: [], nextCursor: nil)
        }
    }

    private func listTaskPageOnce(
        cursor: String?,
        limit: Int
    ) async throws -> TaskSummaryPage {
        try await ensureInitialized()
        return try await listTaskPageUsingThreadList(
            cursor: cursor,
            limit: min(100, max(1, limit))
        )
    }

    private func listTaskPageUsingThreadList(
        cursor: String?,
        limit: Int
    ) async throws -> TaskSummaryPage {
        var params: [String: Any] = [
            "limit": limit,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "archived": false,
            "useStateDbOnly": true,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        let page: ThreadListPage = try await request(
            method: "thread/list",
            params: params
        )
        return TaskSummaryPage(
            tasks: page.data.map {
                TranscriptNormalizer.taskSummary(from: $0)
            },
            nextCursor: normalizedCursor(page.nextCursor)
        )
    }

    private func listTasksOnce() async throws -> [TaskSummary] {
        try await ensureInitialized()

        var cursor: String?
        var summaries: [TaskSummary] = []
        var seen = Set<String>()
        var seenCursors = Set<String>()

        repeat {
            let remaining = configuration.maximumTaskCount - summaries.count
            guard remaining > 0 else { break }

            let page = try await listTaskPageUsingThreadList(
                cursor: cursor,
                limit: min(configuration.pageSize, remaining)
            )
            for summary in page.tasks where seen.insert(summary.id).inserted {
                summaries.append(summary)
                if summaries.count == configuration.maximumTaskCount {
                    break
                }
            }
            if let nextCursor = page.nextCursor,
               seenCursors.insert(nextCursor).inserted {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return summaries.sorted {
            if $0.updatedAt == $1.updatedAt { return $0.id < $1.id }
            return $0.updatedAt > $1.updatedAt
        }
    }

    /// Reads one page of text messages without waiting for the entire thread.
    ///
    /// The first call requests the newest turns. Subsequent calls pass the
    /// returned `nextCursor` to walk backwards through older history. Messages
    /// in every returned page are ordered chronologically.
    public func readSelectableMessagePage(
        threadId: String,
        cursor: String? = nil,
        limit: Int? = nil
    ) async throws -> SelectableMessagePage {
        try await withReconnectRetry {
            try await self.readSelectableMessagePageOnce(
                threadId: threadId,
                cursor: cursor,
                limit: limit
            )
        }
    }

    private func readSelectableMessagePageOnce(
        threadId: String,
        cursor: String?,
        limit: Int?
    ) async throws -> SelectableMessagePage {
        try await ensureInitialized()

        let effectiveLimit = min(
            100,
            max(1, limit ?? configuration.messagePageSize)
        )
        var params: [String: Any] = [
            "threadId": threadId,
            "sortDirection": "desc",
            "itemsView": "full",
            "limit": effectiveLimit,
        ]
        if let cursor {
            params["cursor"] = cursor
        }

        do {
            let page: ThreadTurnsListPage = try await request(
                method: "thread/turns/list",
                params: params
            )

            // The server returns newest-first. Remove any duplicate turn in
            // this response before reversing so each page is oldest-first.
            var seenTurnIDs = Set<String>()
            let newestFirst = page.data.filter {
                seenTurnIDs.insert($0.id).inserted
            }
            let messages = TranscriptNormalizer.messages(
                turns: Array(newestFirst.reversed())
            )
            return SelectableMessagePage(
                messages: deduplicatingMessages(messages),
                nextCursor: normalizedCursor(page.nextCursor)
            )
        } catch is ExperimentalMethodUnavailable {
            // A bounded, paged endpoint is required. Do not replace it with an
            // unbounded full-conversation request on large tool-heavy tasks.
            throw AppServerClientError.fastPaginationUnavailable
        }
    }

    private func normalizedCursor(_ cursor: String?) -> String? {
        guard let cursor, !cursor.isEmpty else { return nil }
        return cursor
    }

    private func deduplicatingMessages(
        _ messages: [SelectableMessage]
    ) -> [SelectableMessage] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0.id).inserted }
    }

    public func shutdown() async {
        await stopConnection()
    }

    private func withReconnectRetry<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch AppServerClientError.processUnavailable {
            await stopConnection()
            return try await operation()
        }
    }

    private func ensureInitialized() async throws {
        try Task.checkCancellation()
        while let attempt = shutdownAttempt {
            await attempt.task.value
            if shutdownAttempt?.generation == attempt.generation {
                shutdownAttempt = nil
            }
            try Task.checkCancellation()
        }

        guard !initialized else { return }

        if let attempt = initializationAttempt {
            try await attempt.task.value
            try Task.checkCancellation()
            return
        }

        connectionGeneration &+= 1
        let generation = connectionGeneration
        let task = Task { [weak self] in
            guard let self else {
                throw AppServerClientError.processUnavailable
            }
            try await self.initializeConnection(generation: generation)
        }
        initializationAttempt = InitializationAttempt(
            generation: generation,
            task: task
        )

        do {
            try await task.value
            if initializationAttempt?.generation == generation {
                initializationAttempt = nil
            }
            try Task.checkCancellation()
        } catch {
            if initializationAttempt?.generation == generation {
                initializationAttempt = nil
            }
            throw error
        }
    }

    private func initializeConnection(generation: UInt64) async throws {
        try validateInitialization(generation: generation)
        let activeTransport: any LineRPCTransport
        if let transport {
            activeTransport = transport
        } else {
            let newTransport = try transportFactory()
            transport = newTransport
            activeTransport = newTransport
        }

        do {
            try await activeTransport.start()
            try validateInitialization(generation: generation)
            let _: InitializeResult = try await performRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "codex-export",
                        "title": "Codex Export",
                        "version": configuration.clientVersion,
                    ],
                    "capabilities": [
                        "experimentalApi": true,
                        "requestAttestation": false,
                    ],
                ],
                transport: activeTransport
            )
            try validateInitialization(generation: generation)
            let initializedNotification = try JSONSerialization.data(
                withJSONObject: [
                    "method": "initialized",
                    "params": [String: Any](),
                ]
            )
            try await activeTransport.notify(initializedNotification)
            try validateInitialization(generation: generation)
            initialized = true
        } catch {
            if connectionGeneration == generation {
                transport = nil
                initialized = false
                await activeTransport.shutdown()
            }
            throw error
        }
    }

    private func validateInitialization(generation: UInt64) throws {
        try Task.checkCancellation()
        guard connectionGeneration == generation else {
            throw CancellationError()
        }
    }

    private func stopConnection() async {
        connectionGeneration &+= 1
        initializationAttempt?.task.cancel()
        initializationAttempt = nil
        initialized = false

        let activeTransport = transport
        transport = nil
        let previousShutdown = shutdownAttempt?.task
        let generation = connectionGeneration
        let task = Task {
            if let previousShutdown {
                await previousShutdown.value
            }
            await activeTransport?.shutdown()
        }
        shutdownAttempt = ShutdownAttempt(generation: generation, task: task)
        await task.value
        if shutdownAttempt?.generation == generation {
            shutdownAttempt = nil
        }
    }

    private func request<Result: Decodable>(
        method: String,
        params: [String: Any]
    ) async throws -> Result {
        guard let transport else {
            throw AppServerClientError.processUnavailable
        }
        return try await performRequest(
            method: method,
            params: params,
            transport: transport
        )
    }

    private func performRequest<Result: Decodable>(
        method: String,
        params: [String: Any],
        transport: any LineRPCTransport
    ) async throws -> Result {
        let id = nextID
        nextID += 1
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "method": method,
            "params": params,
        ])
        let response = try await transport.send(request: data, id: id)
        let envelope = try JSONDecoder().decode(RPCEnvelope<Result>.self, from: response)
        if let error = envelope.error {
            if (method == "thread/turns/list" || method == "thread/search"),
               isExplicitlyUnavailableExperimentalMethod(error) {
                throw ExperimentalMethodUnavailable()
            }
            throw AppServerClientError.rpcError(code: error.code)
        }
        guard let result = envelope.result else {
            throw AppServerClientError.invalidResponse
        }
        return result
    }

    private func isExplicitlyUnavailableExperimentalMethod(
        _ error: RPCError
    ) -> Bool {
        if error.code == -32_601 { return true }
        let message = error.message.lowercased()
        return message.contains("method not found")
            || message.contains("unknown method")
            || message.contains("unsupported method")
            || message.contains("not supported")
            || message.contains("experimental api")
            || message.contains("experimentalapi")
            || message.contains("requires experimental")
            || message.contains("experimental method")
    }
}
