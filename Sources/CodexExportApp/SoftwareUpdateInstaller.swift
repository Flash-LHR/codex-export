import Darwin
import CodexExportCore
import Foundation

enum SoftwareUpdateInstaller {
    static let helperArgument = "--software-update-helper"
    static let healthArgument = "--software-update-health-token"

    private static let healthTimeout: TimeInterval = 20
    private static let healthStabilityWindow: TimeInterval = 2
    private static let pollInterval: TimeInterval = 0.05
    private static let toolExecutionTimeout: TimeInterval = 5 * 60

    private enum InstallerError: Error {
        case invalidArguments
        case invalidPath
        case lockUnavailable
        case cancelled
        case copyFailed
        case invalidApplication
        case swapFailed(Int32)
        case launchFailed
        case healthCheckFailed
    }

    private struct Plan {
        let target: URL
        let sourceApplication: URL
        let workingDirectory: URL
        let parentPID: pid_t
        let bundleIdentifier: String
        let version: String
        let build: Int
        let token: UUID
        let readyMarker: URL
        let cancelMarker: URL

        var parentDirectory: URL { target.deletingLastPathComponent() }
        var incoming: URL {
            parentDirectory.appendingPathComponent(
                ".Codex Export.app.incoming.\(token.uuidString)",
                isDirectory: true
            )
        }
        var lockFile: URL {
            parentDirectory.appendingPathComponent(
                ".Codex Export.app.update.lock",
                isDirectory: false
            )
        }
        var healthMarker: URL { healthMarkerURL(for: token) }
    }

    static func runIfRequested(arguments: [String]) -> Int32? {
        guard arguments.dropFirst().first == helperArgument else { return nil }
        do {
            let plan = try parsePlan(arguments: arguments)
            try install(plan)
            return EXIT_SUCCESS
        } catch {
            FileHandle.standardError.write(
                Data("software update installer failed: \(error)\n".utf8)
            )
            return EXIT_FAILURE
        }
    }

    static func reportHealthIfRequested(arguments: [String]) {
        guard let index = arguments.firstIndex(of: healthArgument),
              arguments.indices.contains(index + 1),
              let token = UUID(uuidString: arguments[index + 1]) else {
            return
        }
        let marker = healthMarkerURL(for: token)
        do {
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(token.uuidString.utf8).write(to: marker, options: .atomic)
        } catch {
            // The installer treats a missing marker as a failed launch and
            // rolls back. Health reporting must never crash the new app.
        }
    }

    static func healthMarkerURL(for token: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
            .appendingPathComponent("Health", isDirectory: true)
            .appendingPathComponent(token.uuidString, isDirectory: false)
    }

    private static func parsePlan(arguments: [String]) throws -> Plan {
        let values = Array(arguments.dropFirst(2))
        guard values.count == 9,
              let parentPID = pid_t(values[3]),
              parentPID > 1,
              let build = Int(values[6]),
              build > 0,
              let token = UUID(uuidString: values[7]) else {
            throw InstallerError.invalidArguments
        }

        let targetInput = URL(fileURLWithPath: values[0]).standardizedFileURL
        let sourceInput = URL(fileURLWithPath: values[1]).standardizedFileURL
        let workingInput = URL(fileURLWithPath: values[2]).standardizedFileURL
        guard isDirectoryWithoutSymlink(targetInput),
              isDirectoryWithoutSymlink(sourceInput),
              isDirectoryWithoutSymlink(workingInput) else {
            throw InstallerError.invalidPath
        }
        let target = targetInput.resolvingSymlinksInPath()
        let source = sourceInput.resolvingSymlinksInPath()
        let workingDirectory = workingInput.resolvingSymlinksInPath()
        let updateRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
            .resolvingSymlinksInPath()
        let readyMarker = URL(fileURLWithPath: values[8])
            .resolvingSymlinksInPath()
        let cancelMarker = workingDirectory.appendingPathComponent(
            ".installer-cancel.\(token.uuidString)",
            isDirectory: false
        )

        guard target.path.hasPrefix("/"),
              target.lastPathComponent == "Codex Export.app",
              target.pathExtension == "app",
              target.deletingLastPathComponent().path != "/",
              workingDirectory.path.hasPrefix(updateRoot.path + "/"),
              source.path.hasPrefix(workingDirectory.path + "/"),
              readyMarker.deletingLastPathComponent() == workingDirectory,
              readyMarker.lastPathComponent == ".installer-ready.\(token.uuidString)" else {
            throw InstallerError.invalidPath
        }

        return Plan(
            target: target,
            sourceApplication: source,
            workingDirectory: workingDirectory,
            parentPID: parentPID,
            bundleIdentifier: values[4],
            version: values[5],
            build: build,
            token: token,
            readyMarker: readyMarker,
            cancelMarker: cancelMarker
        )
    }

    private static func install(_ plan: Plan) throws {
        let fileManager = FileManager.default
        let lockDescriptor = try acquireLock(at: plan.lockFile)
        defer {
            flock(lockDescriptor, LOCK_UN)
            close(lockDescriptor)
        }

        guard !fileManager.fileExists(atPath: plan.incoming.path) else {
            throw InstallerError.invalidPath
        }
        let isCancelled = { markerContains(plan.cancelMarker, token: plan.token) }
        try validateApplication(
            at: plan.target,
            bundleIdentifier: plan.bundleIdentifier,
            version: nil,
            build: nil,
            isCancelled: isCancelled
        )
        try requireStrictUpgrade(plan)
        try validateApplication(
            at: plan.sourceApplication,
            bundleIdentifier: plan.bundleIdentifier,
            version: plan.version,
            build: plan.build,
            isCancelled: isCancelled
        )
        try checkCancellation(plan)

        var shouldRemoveIncoming = true
        defer {
            if shouldRemoveIncoming {
                try? fileManager.removeItem(at: plan.incoming)
            }
            try? fileManager.removeItem(at: plan.readyMarker)
            try? fileManager.removeItem(at: plan.cancelMarker)
        }
        do {
            try runTool(
                "/usr/bin/ditto",
                arguments: [plan.sourceApplication.path, plan.incoming.path],
                isCancelled: isCancelled
            )
        } catch {
            throw InstallerError.copyFailed
        }

        try validateApplication(
            at: plan.incoming,
            bundleIdentifier: plan.bundleIdentifier,
            version: plan.version,
            build: plan.build,
            isCancelled: isCancelled
        )
        try checkCancellation(plan)
        try Data(plan.token.uuidString.utf8).write(
            to: plan.readyMarker,
            options: .atomic
        )

        while getppid() == plan.parentPID {
            try checkCancellation(plan)
            Thread.sleep(forTimeInterval: 0.1)
        }
        var isSwapped = false
        do {
            try checkCancellation(plan)
            try? fileManager.removeItem(at: plan.workingDirectory)

            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)

            // The target may have been replaced while this helper waited for
            // its parent. Never let an older prepared candidate overwrite a
            // newer build installed by another actor.
            try requireStrictUpgrade(plan)
            try atomicSwap(plan.target, plan.incoming)
            isSwapped = true
            try validateApplication(
                at: plan.target,
                bundleIdentifier: plan.bundleIdentifier,
                version: plan.version,
                build: plan.build
            )
            let newProcess = try launchNewApplication(plan)
            guard waitForHealth(plan, process: newProcess) else {
                terminate(newProcess)
                throw InstallerError.healthCheckFailed
            }

            isSwapped = false
            shouldRemoveIncoming = true
            clearFailureRecord(bundleIdentifier: plan.bundleIdentifier)
            try? fileManager.removeItem(at: plan.healthMarker)
        } catch {
            if isSwapped {
                do {
                    try atomicSwap(plan.target, plan.incoming)
                    isSwapped = false
                } catch {
                    // Preserve the old application at the incoming path for
                    // manual recovery if even the atomic rollback fails.
                    shouldRemoveIncoming = false
                }
            }
            recordFailure(plan)
            _ = try? launchTool(
                "/usr/bin/open",
                arguments: [plan.target.path]
            )
            throw error
        }
    }

    private static func acquireLock(at url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw InstallerError.lockUnavailable }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_uid == getuid(),
              status.st_mode & S_IFMT == S_IFREG,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw InstallerError.lockUnavailable
        }
        return descriptor
    }

    private static func checkCancellation(_ plan: Plan) throws {
        guard !markerContains(plan.cancelMarker, token: plan.token) else {
            throw InstallerError.cancelled
        }
    }

    private static func markerContains(_ url: URL, token: UUID) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else {
            return false
        }
        return value == token.uuidString
    }

    private static func atomicSwap(_ first: URL, _ second: URL) throws {
        // The paths have already been canonicalized and their final
        // components lstat-checked. RENAME_NOFOLLOW_ANY rejects macOS firmlink
        // components such as /private/var even when no user symlink exists.
        let flags = UInt32(RENAME_SWAP)
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, flags)
            }
        }
        guard result == 0 else { throw InstallerError.swapFailed(errno) }
    }

    private static func launchNewApplication(_ plan: Plan) throws -> Process {
        let executable = try applicationExecutable(at: plan.target)
        let process = Process()
        process.executableURL = executable
        process.arguments = [healthArgument, plan.token.uuidString]
        process.environment = sanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw InstallerError.launchFailed
        }
        return process
    }

    private static func waitForHealth(_ plan: Plan, process: Process) -> Bool {
        let deadline = Date().addingTimeInterval(healthTimeout)
        while Date() < deadline {
            guard process.isRunning else { return false }
            if markerContains(plan.healthMarker, token: plan.token) {
                let observedAt = Date()
                let markerDate = (
                    try? FileManager.default.attributesOfItem(
                        atPath: plan.healthMarker.path
                    )[.modificationDate]
                ) as? Date
                let healthySince = min(markerDate ?? observedAt, observedAt)
                let stableUntil = healthySince.addingTimeInterval(
                    healthStabilityWindow
                )
                while Date() < stableUntil {
                    guard process.isRunning else { return false }
                    Thread.sleep(forTimeInterval: pollInterval)
                }
                return process.isRunning
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return false
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func validateApplication(
        at url: URL,
        bundleIdentifier: String,
        version: String?,
        build: Int?,
        isCancelled: (() -> Bool)? = nil
    ) throws {
        guard isDirectoryWithoutSymlink(url) else {
            throw InstallerError.invalidApplication
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == bundleIdentifier,
              let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty,
              executable == URL(fileURLWithPath: executable).lastPathComponent
        else {
            throw InstallerError.invalidApplication
        }
        if let version,
           plist["CFBundleShortVersionString"] as? String != version {
            throw InstallerError.invalidApplication
        }
        if let build {
            guard let rawBuild = plist["CFBundleVersion"] as? String,
                  Int(rawBuild) == build else {
                throw InstallerError.invalidApplication
            }
        }
        guard FileManager.default.isExecutableFile(
            atPath: url.appendingPathComponent(
                "Contents/MacOS/\(executable)"
            ).path
        ) else {
            throw InstallerError.invalidApplication
        }
        do {
            try runTool(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", url.path],
                isCancelled: isCancelled
            )
        } catch {
            throw InstallerError.invalidApplication
        }
    }

    private static func applicationExecutable(at app: URL) throws -> URL {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let name = plist["CFBundleExecutable"] as? String,
              name == URL(fileURLWithPath: name).lastPathComponent else {
            throw InstallerError.invalidApplication
        }
        return app.appendingPathComponent("Contents/MacOS/\(name)")
    }

    private static func requireStrictUpgrade(_ plan: Plan) throws {
        let infoURL = plan.target.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let currentVersion = plist["CFBundleShortVersionString"] as? String,
              let currentBuildString = plist["CFBundleVersion"] as? String,
              let currentBuild = UInt64(currentBuildString),
              let candidateBuild = UInt64(exactly: plan.build),
              let current = try? SoftwareVersion(
                marketingVersion: currentVersion,
                buildNumber: currentBuild
              ),
              let candidate = try? SoftwareVersion(
                marketingVersion: plan.version,
                buildNumber: candidateBuild
              ) else {
            throw InstallerError.invalidApplication
        }
        do {
            try SoftwareUpdateSecurity.requireUpgrade(
                candidate: candidate,
                over: current
            )
        } catch {
            throw InstallerError.invalidApplication
        }
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private static func runTool(
        _ executable: String,
        arguments: [String],
        isCancelled: (() -> Bool)? = nil
    ) throws {
        let process = try launchTool(executable, arguments: arguments)
        let deadline = Date().addingTimeInterval(toolExecutionTimeout)
        while process.isRunning {
            if isCancelled?() == true {
                terminate(process)
                throw InstallerError.cancelled
            }
            guard Date() < deadline else {
                terminate(process)
                throw InstallerError.invalidApplication
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        guard process.terminationStatus == 0 else {
            throw InstallerError.invalidApplication
        }
    }

    @discardableResult
    private static func launchTool(
        _ executable: String,
        arguments: [String]
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = sanitizedEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    private static func sanitizedEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key != "BASH_ENV"
                && key != "ENV"
                && !key.hasPrefix("DYLD_")
                && !key.hasPrefix("CODEX_EXPORT_UPDATE_")
        }
    }

    private static func recordFailure(_ plan: Plan) {
        guard let defaults = UserDefaults(suiteName: plan.bundleIdentifier) else {
            return
        }
        defaults.set(plan.version, forKey: "automaticUpdateFailedVersion.v1")
        defaults.set(plan.build, forKey: "automaticUpdateFailedBuild.v1")
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: "automaticUpdateFailedAt.v1"
        )
    }

    private static func clearFailureRecord(bundleIdentifier: String) {
        guard let defaults = UserDefaults(suiteName: bundleIdentifier) else {
            return
        }
        defaults.removeObject(forKey: "automaticUpdateFailedVersion.v1")
        defaults.removeObject(forKey: "automaticUpdateFailedBuild.v1")
        defaults.removeObject(forKey: "automaticUpdateFailedAt.v1")
    }
}
