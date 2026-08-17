import CodexExportCore
import CodexExportFeature
import Darwin
import Foundation

/// Makes the installer READY acknowledgement and caller cancellation a
/// single-winner decision. Without this gate, cancellation can write the
/// helper's cancel marker after READY has been observed but before the service
/// returns, which would let the app terminate while the helper exits.
final class InstallerLaunchReadinessGate: @unchecked Sendable {
    private enum State {
        case waiting
        case ready
        case cancelled
    }

    private let lock = NSLock()
    private var state = State.waiting

    /// Returns true only when READY wins the decision.
    func acceptReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .waiting else { return state == .ready }
        state = .ready
        return true
    }

    /// Returns true only for the cancellation that wins the decision.
    func requestCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .waiting else { return false }
        state = .cancelled
        return true
    }
}

private enum GitHubSoftwareUpdateError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case releaseMetadataTooLarge
    case updateArchiveTooLarge
    case downloadedSizeMismatch
    case extractionFailed
    case invalidApplicationBundle
    case applicationIdentityMismatch
    case applicationVersionMismatch
    case applicationSignatureInvalid
    case unsupportedArchitecture
    case installationLocationNotWritable
    case installerLaunchFailed
    case recentInstallerFailure

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "GitHub 返回了无效的更新响应。"
        case let .httpStatus(status):
            return "GitHub 更新请求失败（HTTP \(status)）。"
        case .releaseMetadataTooLarge:
            return "更新元数据异常。"
        case .updateArchiveTooLarge:
            return "更新包超过允许的大小。"
        case .downloadedSizeMismatch:
            return "更新包大小与签名清单不一致。"
        case .extractionFailed:
            return "无法解压更新包。"
        case .invalidApplicationBundle:
            return "更新包中没有唯一有效的 Codex Export 应用。"
        case .applicationIdentityMismatch:
            return "更新应用的身份不匹配。"
        case .applicationVersionMismatch:
            return "更新应用的版本不匹配。"
        case .applicationSignatureInvalid:
            return "更新应用的代码签名无效。"
        case .unsupportedArchitecture:
            return "更新应用不支持当前 Mac 架构。"
        case .installationLocationNotWritable:
            return "当前安装位置不可写，无法静默更新。"
        case .installerLaunchFailed:
            return "无法启动后台安装器。"
        case .recentInstallerFailure:
            return "该版本最近安装失败，将在稍后自动重试。"
        }
    }
}

actor GitHubSoftwareUpdateService: SoftwareUpdateServicing {
    private static let maximumMetadataBytes = 64 * 1_024
    private static let maximumArchiveBytes: UInt64 = 256 * 1_024 * 1_024
    private static let failedInstallerRetryInterval: TimeInterval = 6 * 60 * 60
    private static let toolExecutionTimeout: TimeInterval = 5 * 60
    private static let processTerminationGrace: TimeInterval = 2
    private static let failureVersionKey = "automaticUpdateFailedVersion.v1"
    private static let failureBuildKey = "automaticUpdateFailedBuild.v1"
    private static let failureTimeKey = "automaticUpdateFailedAt.v1"

    private let configuration: SoftwareUpdateConfiguration
    private let session: URLSession
    private let fileManager: FileManager

    init(
        configuration: SoftwareUpdateConfiguration,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.session = session
        self.fileManager = fileManager
    }

    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate? {
        let manifestURL = configuration.latestReleaseAssetURL(
            named: SoftwareUpdateConfiguration.manifestAssetName
        )
        let signatureURL = configuration.latestReleaseAssetURL(
            named: SoftwareUpdateConfiguration.signatureAssetName
        )

        async let manifestData = fetchData(
            request: URLRequest(url: manifestURL),
            maximumBytes: Self.maximumMetadataBytes
        )
        async let signatureData = fetchData(
            request: URLRequest(url: signatureURL),
            maximumBytes: 128
        )
        let authenticated = try SoftwareUpdateSecurity.authenticateManifest(
            await manifestData,
            detachedSignature: await signatureData,
            publicKey: configuration.publicKey,
            expectedBundleIdentifier: configuration.bundleIdentifier
        )
        let expectedAssetName = "Codex-Export-\(authenticated.semanticVersion).zip"
        guard authenticated.manifest.assetName == expectedAssetName else {
            throw SoftwareUpdateError.invalidAssetName(
                authenticated.manifest.assetName
            )
        }

        guard authenticated.manifest.build <= UInt64(Int.max) else {
            throw SoftwareUpdateError.invalidBuildNumber(
                authenticated.manifest.build
            )
        }

        let current = try SoftwareVersion(
            marketingVersion: currentVersion,
            buildNumber: UInt64(max(0, currentBuild))
        )
        let candidate = authenticated.softwareVersion
        if candidate.buildNumber <= current.buildNumber {
            return nil
        }
        try SoftwareUpdateSecurity.requireUpgrade(
            candidate: candidate,
            over: current
        )

        let archiveURL = try latestReleaseAssetURL(
            named: authenticated.manifest.assetName
        )
        try rejectRecentInstallerFailure(
            version: authenticated.semanticVersion.description,
            build: Int(authenticated.manifest.build)
        )

        return SoftwareUpdateCandidate(
            version: authenticated.semanticVersion.description,
            build: Int(authenticated.manifest.build),
            assetName: authenticated.manifest.assetName,
            assetURL: archiveURL,
            sha256: authenticated.normalizedSHA256,
            size: authenticated.manifest.size
        )
    }

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate {
        guard candidate.size <= Self.maximumArchiveBytes else {
            throw GitHubSoftwareUpdateError.updateArchiveTooLarge
        }
        try validateReleaseDownloadURL(
            candidate.assetURL,
            assetName: candidate.assetName
        )

        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let workingDirectory = root.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        do {
            let request = URLRequest(url: candidate.assetURL)
            let (temporaryDownload, response) = try await session.download(for: request)
            try validate(response: response)
            try Task.checkCancellation()

            let archiveURL = workingDirectory.appendingPathComponent(
                candidate.assetName,
                isDirectory: false
            )
            try fileManager.moveItem(at: temporaryDownload, to: archiveURL)
            let attributes = try fileManager.attributesOfItem(atPath: archiveURL.path)
            guard let byteCount = (attributes[.size] as? NSNumber)?.uint64Value,
                  byteCount == candidate.size else {
                throw GitHubSoftwareUpdateError.downloadedSizeMismatch
            }
            let archiveData = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
            try SoftwareUpdateSecurity.verifySHA256(candidate.sha256, of: archiveData)
            try Task.checkCancellation()

            let extractedDirectory = workingDirectory.appendingPathComponent(
                "Extracted",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: extractedDirectory,
                withIntermediateDirectories: false
            )
            try runTool(
                "/usr/bin/ditto",
                arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path],
                failure: .extractionFailed
            )
            try Task.checkCancellation()

            let appBundleURL = try findUniqueApplication(in: extractedDirectory)
            try validateApplication(
                at: appBundleURL,
                version: candidate.version,
                build: candidate.build
            )
            return PreparedSoftwareUpdate(
                version: candidate.version,
                build: candidate.build,
                workingDirectory: workingDirectory,
                appBundleURL: appBundleURL
            )
        } catch {
            try? fileManager.removeItem(at: workingDirectory)
            throw error
        }
    }

    func launchInstaller(
        for update: PreparedSoftwareUpdate
    ) async throws {
        try validatePreparedUpdate(update)
        let target = configuration.targetBundleURL
        let parent = target.deletingLastPathComponent()
        guard target.pathExtension == "app",
              target.lastPathComponent == "Codex Export.app",
              parent.path != "/",
              fileManager.isWritableFile(atPath: parent.path),
              fileManager.fileExists(atPath: target.path) else {
            throw GitHubSoftwareUpdateError.installationLocationNotWritable
        }

        guard let executable = Bundle.main.executableURL else {
            throw GitHubSoftwareUpdateError.installerLaunchFailed
        }
        let token = UUID()
        let readyMarker = update.workingDirectory.appendingPathComponent(
            ".installer-ready.\(token.uuidString)",
            isDirectory: false
        )
        let cancelMarker = update.workingDirectory.appendingPathComponent(
            ".installer-cancel.\(token.uuidString)",
            isDirectory: false
        )
        try? fileManager.removeItem(at: readyMarker)
        try? fileManager.removeItem(at: cancelMarker)

        let process = Process()
        process.executableURL = executable
        process.arguments = [
            SoftwareUpdateInstaller.helperArgument,
            target.path,
            update.appBundleURL.path,
            update.workingDirectory.path,
            String(ProcessInfo.processInfo.processIdentifier),
            configuration.bundleIdentifier,
            update.version,
            String(update.build),
            token.uuidString,
            readyMarker.path
        ]
        process.environment = sanitizedHelperEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw GitHubSoftwareUpdateError.installerLaunchFailed
        }

        let readinessGate = InstallerLaunchReadinessGate()
        let requestCancellation: @Sendable () -> Void = {
            guard readinessGate.requestCancellation() else { return }
            try? Data(token.uuidString.utf8).write(to: cancelMarker, options: .atomic)
        }
        do {
            try await withTaskCancellationHandler {
                for _ in 0..<600 {
                    if Self.markerContains(readyMarker, token: token) {
                        guard readinessGate.acceptReady() else {
                            throw CancellationError()
                        }
                        return
                    }
                    try Task.checkCancellation()
                    guard process.isRunning else {
                        throw GitHubSoftwareUpdateError.installerLaunchFailed
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                throw GitHubSoftwareUpdateError.installerLaunchFailed
            } onCancel: {
                requestCancellation()
            }
        } catch {
            requestCancellation()
            Self.waitForExitOrTerminate(
                process,
                grace: Self.processTerminationGrace
            )
            if error is CancellationError {
                throw CancellationError()
            }
            throw GitHubSoftwareUpdateError.installerLaunchFailed
        }
    }

    func discard(_ update: PreparedSoftwareUpdate) async {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
            .standardizedFileURL
        let candidate = update.workingDirectory.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { return }
        try? fileManager.removeItem(at: candidate)
    }

    private func fetchData(
        request: URLRequest,
        maximumBytes: Int
    ) async throws -> Data {
        var request = request
        request.timeoutInterval = 30
        request.setValue("Codex-Export-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try validate(response: response)
        guard data.count <= maximumBytes else {
            throw GitHubSoftwareUpdateError.releaseMetadataTooLarge
        }
        return data
    }

    private func validate(response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https" else {
            throw GitHubSoftwareUpdateError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw GitHubSoftwareUpdateError.httpStatus(response.statusCode)
        }
    }

    private func latestReleaseAssetURL(named assetName: String) throws -> URL {
        guard !assetName.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            throw SoftwareUpdateError.invalidAssetName(assetName)
        }
        return configuration.latestReleaseAssetURL(named: assetName)
    }

    private func validateReleaseDownloadURL(
        _ url: URL,
        assetName: String
    ) throws {
        let expectedURL = try latestReleaseAssetURL(named: assetName)
        guard url == expectedURL else {
            throw GitHubSoftwareUpdateError.invalidResponse
        }
    }

    private func findUniqueApplication(in directory: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw GitHubSoftwareUpdateError.invalidApplicationBundle
        }

        var applications: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey
            ])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isDirectory == true, url.pathExtension == "app" {
                applications.append(url)
                enumerator.skipDescendants()
            }
        }
        guard applications.count == 1, let app = applications.first else {
            throw GitHubSoftwareUpdateError.invalidApplicationBundle
        }
        return app
    }

    private func validateApplication(
        at appURL: URL,
        version: String,
        build: Int
    ) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == configuration.bundleIdentifier else {
            throw GitHubSoftwareUpdateError.applicationIdentityMismatch
        }
        guard info["CFBundleShortVersionString"] as? String == version,
              let buildString = info["CFBundleVersion"] as? String,
              Int(buildString) == build else {
            throw GitHubSoftwareUpdateError.applicationVersionMismatch
        }

        try runTool(
            "/usr/bin/codesign",
            arguments: ["--verify", "--deep", "--strict", appURL.path],
            failure: .applicationSignatureInvalid
        )
        let executableName = info["CFBundleExecutable"] as? String
        guard let executableName, !executableName.isEmpty else {
            throw GitHubSoftwareUpdateError.invalidApplicationBundle
        }
        let executableURL = appURL.appendingPathComponent(
            "Contents/MacOS/\(executableName)"
        )
        try runTool(
            "/usr/bin/lipo",
            arguments: [executableURL.path, "-verify_arch", "arm64"],
            failure: .unsupportedArchitecture
        )
    }

    private func validatePreparedUpdate(
        _ update: PreparedSoftwareUpdate
    ) throws {
        let root = update.workingDirectory.standardizedFileURL
        let app = update.appBundleURL.standardizedFileURL
        guard app.path.hasPrefix(root.path + "/") else {
            throw GitHubSoftwareUpdateError.invalidApplicationBundle
        }
        try validateApplication(
            at: app,
            version: update.version,
            build: update.build
        )
    }

    private func runTool(
        _ executable: String,
        arguments: [String],
        failure: GitHubSoftwareUpdateError
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw failure
        }
        let deadline = Date().addingTimeInterval(Self.toolExecutionTimeout)
        while process.isRunning {
            if Task.isCancelled {
                Self.terminate(process, grace: Self.processTerminationGrace)
                throw CancellationError()
            }
            guard Date() < deadline else {
                Self.terminate(process, grace: Self.processTerminationGrace)
                throw failure
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard process.terminationStatus == 0 else { throw failure }
    }

    private static func waitForExitOrTerminate(
        _ process: Process,
        grace: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            terminate(process, grace: grace)
        }
    }

    private static func terminate(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(grace)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func rejectRecentInstallerFailure(version: String, build: Int) throws {
        guard let defaults = UserDefaults(suiteName: configuration.bundleIdentifier),
              defaults.string(forKey: Self.failureVersionKey) == version,
              defaults.integer(forKey: Self.failureBuildKey) == build else {
            return
        }
        let failedAt = defaults.double(forKey: Self.failureTimeKey)
        let now = Date().timeIntervalSince1970
        guard failedAt > 0,
              failedAt <= now + Self.failedInstallerRetryInterval,
              max(0, now - failedAt) < Self.failedInstallerRetryInterval else {
            return
        }
        throw GitHubSoftwareUpdateError.recentInstallerFailure
    }

    private func sanitizedHelperEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            key != "BASH_ENV"
                && key != "ENV"
                && !key.hasPrefix("DYLD_")
                && !key.hasPrefix("CODEX_EXPORT_UPDATE_")
        }
    }

    private static func markerContains(_ url: URL, token: UUID) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let value = String(data: data, encoding: .utf8) else {
            return false
        }
        return value == token.uuidString
    }

}

enum UnavailableSoftwareUpdateError: LocalizedError {
    case notConfigured

    var errorDescription: String? {
        "自动更新尚未配置公开仓库和签名公钥。"
    }
}

actor UnavailableSoftwareUpdateService: SoftwareUpdateServicing {
    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate? {
        nil
    }

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate {
        throw UnavailableSoftwareUpdateError.notConfigured
    }

    func launchInstaller(
        for update: PreparedSoftwareUpdate
    ) async throws {
        throw UnavailableSoftwareUpdateError.notConfigured
    }

    func discard(_ update: PreparedSoftwareUpdate) async {}
}
