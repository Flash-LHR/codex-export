import Foundation

public struct SoftwareUpdateCandidate: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let assetName: String
    public let assetURL: URL
    public let sha256: String
    public let size: UInt64

    public init(
        version: String,
        build: Int,
        assetName: String,
        assetURL: URL,
        sha256: String,
        size: UInt64
    ) {
        self.version = version
        self.build = build
        self.assetName = assetName
        self.assetURL = assetURL
        self.sha256 = sha256
        self.size = size
    }
}

public struct PreparedSoftwareUpdate: Equatable, Sendable {
    public let version: String
    public let build: Int
    public let workingDirectory: URL
    public let appBundleURL: URL

    public init(
        version: String,
        build: Int,
        workingDirectory: URL,
        appBundleURL: URL
    ) {
        self.version = version
        self.build = build
        self.workingDirectory = workingDirectory
        self.appBundleURL = appBundleURL
    }
}

public protocol SoftwareUpdateServicing: Sendable {
    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate?

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate

    /// Launches a detached installer that waits for this process to exit.
    /// Returning means the installer is ready and application termination may
    /// begin; it does not mean replacement has already completed.
    func launchInstaller(
        for update: PreparedSoftwareUpdate
    ) async throws

    func discard(_ update: PreparedSoftwareUpdate) async
}

@MainActor
public protocol SoftwareUpdatePreferenceStoring: AnyObject {
    var automaticUpdatesEnabled: Bool? { get set }
    var knownAvailableVersion: String? { get set }
    var knownAvailableBuild: Int? { get set }
}

@MainActor
public final class SoftwareUpdateController: ObservableObject {
    public enum Phase: Equatable {
        case unavailable
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case updateAvailable(version: String)
        case downloading(version: String)
        case waitingForIdle(version: String)
        case installing(version: String)
        case failed(version: String?, message: String)
    }

    @Published public private(set) var phase: Phase
    @Published public private(set) var isEnabled: Bool

    public let currentVersion: String
    public let isConfigured: Bool

    private let currentBuild: Int
    private let service: any SoftwareUpdateServicing
    private let preferences: any SoftwareUpdatePreferenceStoring
    private let reserveInstallation: @MainActor () -> Bool
    private let releaseInstallationReservation: @MainActor () -> Void
    private let requestTermination: @MainActor () -> Void
    private let initialDelayNanoseconds: UInt64
    private let checkIntervalNanoseconds: UInt64
    private let idlePollNanoseconds: UInt64
    private let shutdownGraceNanoseconds: UInt64
    private var automaticTask: Task<Void, Never>?
    private var retiredTasks: [Task<Void, Never>] = []
    private var runningCycleGenerations = Set<UUID>()
    private var knownAvailableVersion: String?
    private var hasConfirmedCurrentVersion = false
    private var didStart = false
    private var cycleGeneration = UUID()
    private var isInstallerCommitted = false

    public init(
        currentVersion: String,
        currentBuild: Int,
        isConfigured: Bool,
        service: any SoftwareUpdateServicing,
        preferences: any SoftwareUpdatePreferenceStoring,
        reserveInstallation: @escaping @MainActor () -> Bool,
        releaseInstallationReservation: @escaping @MainActor () -> Void,
        requestTermination: @escaping @MainActor () -> Void,
        initialDelayNanoseconds: UInt64 = 5_000_000_000,
        checkIntervalNanoseconds: UInt64 = 21_600_000_000_000,
        idlePollNanoseconds: UInt64 = 1_000_000_000,
        shutdownGraceNanoseconds: UInt64 = 2_000_000_000
    ) {
        self.currentVersion = currentVersion
        self.currentBuild = currentBuild
        self.isConfigured = isConfigured
        self.service = service
        self.preferences = preferences
        self.reserveInstallation = reserveInstallation
        self.releaseInstallationReservation = releaseInstallationReservation
        self.requestTermination = requestTermination
        self.initialDelayNanoseconds = initialDelayNanoseconds
        self.checkIntervalNanoseconds = checkIntervalNanoseconds
        self.idlePollNanoseconds = idlePollNanoseconds
        self.shutdownGraceNanoseconds = shutdownGraceNanoseconds
        isEnabled = preferences.automaticUpdatesEnabled ?? true
        if let version = preferences.knownAvailableVersion,
           let build = preferences.knownAvailableBuild,
           build > currentBuild {
            knownAvailableVersion = version
            phase = isConfigured ? .updateAvailable(version: version) : .unavailable
        } else {
            knownAvailableVersion = nil
            phase = isConfigured ? .idle : .unavailable
        }
    }

    public func start() {
        guard !didStart else { return }
        didStart = true
        guard isConfigured else { return }
        startAutomaticLoop(initialDelayNanoseconds: initialDelayNanoseconds)
    }

    public func toggle() {
        setEnabled(!isEnabled)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isConfigured,
              !isInstallerCommitted,
              enabled != isEnabled else { return }
        isEnabled = enabled
        preferences.automaticUpdatesEnabled = enabled

        if let automaticTask {
            automaticTask.cancel()
            retiredTasks.append(automaticTask)
        }
        automaticTask = nil

        phase = knownAvailableVersion.map(Phase.updateAvailable) ?? .idle
        guard didStart else { return }
        startAutomaticLoop(
            initialDelayNanoseconds: enabled ? 0 : checkIntervalNanoseconds
        )
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .installing:
            return true
        case .unavailable, .idle, .upToDate, .updateAvailable,
             .waitingForIdle, .failed:
            return false
        }
    }

    var canToggle: Bool {
        isConfigured && !isInstallerCommitted
    }

    var hasAvailableUpdate: Bool {
        knownAvailableVersion != nil
    }

    var isConfirmedUpToDate: Bool {
        hasConfirmedCurrentVersion && knownAvailableVersion == nil
    }

    var latestVersion: String? {
        switch phase {
        case let .updateAvailable(version), let .downloading(version),
             let .waitingForIdle(version), let .installing(version):
            return version
        case let .failed(version, _):
            return version
        case .unavailable, .idle, .checking, .upToDate:
            return nil
        }
    }

    var helpText: String {
        let prefix = "当前版本 \(currentVersion)；自动更新"
        switch phase {
        case .unavailable:
            return "\(prefix)尚未配置发布仓库"
        case .idle:
            return "\(prefix)\(isEnabled ? "已开启，等待检查" : "已关闭")"
        case .checking:
            return "\(prefix)正在检查"
        case .upToDate:
            return "\(prefix)\(isEnabled ? "已开启" : "已关闭")；当前已是最新版本"
        case let .updateAvailable(version):
            return "发现新版本 \(version)，准备下载"
        case let .downloading(version):
            return "正在后台下载版本 \(version)"
        case let .waitingForIdle(version):
            return "版本 \(version) 已就绪，将在空闲时自动安装并重启"
        case let .installing(version):
            return "正在安装版本 \(version)，应用即将重新打开"
        case let .failed(_, message):
            return "自动更新失败：\(message)"
        }
    }

    var accessibilityValue: String {
        helpText
    }

    public func shutdown() async {
        didStart = false
        cycleGeneration = UUID()
        let tasks = retiredTasks + [automaticTask].compactMap { $0 }
        for task in tasks { task.cancel() }

        let graceSeconds = Double(shutdownGraceNanoseconds) / 1_000_000_000
        let deadline = ProcessInfo.processInfo.systemUptime + graceSeconds
        while !runningCycleGenerations.isEmpty,
              ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        // Shutdown is deliberately bounded. Any non-cooperative task is still
        // generation-fenced and the process is about to exit.
        retiredTasks = []
        automaticTask = nil
    }

    private func startAutomaticLoop(initialDelayNanoseconds: UInt64) {
        if let automaticTask {
            automaticTask.cancel()
            retiredTasks.append(automaticTask)
        }
        let generation = UUID()
        cycleGeneration = generation
        runningCycleGenerations.insert(generation)
        automaticTask = Task { [weak self] in
            defer { self?.runningCycleGenerations.remove(generation) }
            if initialDelayNanoseconds > 0 {
                do {
                    try await Task.sleep(nanoseconds: initialDelayNanoseconds)
                } catch {
                    return
                }
            }

            while !Task.isCancelled {
                guard let self else { return }
                await self.runUpdateCycle(generation: generation)
                guard self.cycleGeneration == generation else { return }
                guard !Task.isCancelled else { return }
                do {
                    try await Task.sleep(
                        nanoseconds: self.checkIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func runUpdateCycle(generation: UUID) async {
        guard cycleGeneration == generation else { return }
        phase = .checking
        var prepared: PreparedSoftwareUpdate?
        var didReserveInstallation = false
        do {
            let candidate = try await service.latestUpdate(
                currentVersion: currentVersion,
                currentBuild: currentBuild
            )
            try ensureCurrent(generation)
            guard let candidate else {
                knownAvailableVersion = nil
                hasConfirmedCurrentVersion = true
                preferences.knownAvailableVersion = nil
                preferences.knownAvailableBuild = nil
                phase = .upToDate(checkedAt: Date())
                return
            }

            knownAvailableVersion = candidate.version
            hasConfirmedCurrentVersion = false
            preferences.knownAvailableVersion = candidate.version
            preferences.knownAvailableBuild = candidate.build
            phase = .updateAvailable(version: candidate.version)
            guard isEnabled else { return }
            phase = .downloading(version: candidate.version)
            prepared = try await service.prepare(candidate)
            try ensureCurrent(generation)
            guard isEnabled, let prepared else { return }
            phase = .waitingForIdle(version: prepared.version)

            while !reserveInstallation() {
                try ensureCurrent(generation)
                try await Task.sleep(nanoseconds: idlePollNanoseconds)
            }
            didReserveInstallation = true

            try ensureCurrent(generation)
            guard isEnabled else { return }
            phase = .installing(version: prepared.version)
            try await service.launchInstaller(for: prepared)
            // A ready helper is the irreversible commit point. It is already
            // holding the install lock and waiting for this process to exit;
            // a simultaneous toggle must no longer strand it.
            isInstallerCommitted = true
            requestTermination()
        } catch is CancellationError {
            if didReserveInstallation {
                releaseInstallationReservation()
            }
            if let prepared {
                await service.discard(prepared)
            }
        } catch {
            if didReserveInstallation {
                releaseInstallationReservation()
            }
            if let prepared {
                await service.discard(prepared)
            }
            guard cycleGeneration == generation else { return }
            phase = .failed(
                version: knownAvailableVersion,
                message: error.localizedDescription
            )
        }
    }

    private func ensureCurrent(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard cycleGeneration == generation else {
            throw CancellationError()
        }
    }
}
