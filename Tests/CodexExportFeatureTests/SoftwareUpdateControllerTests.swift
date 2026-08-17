import Foundation
import XCTest
@testable import CodexExportFeature

@MainActor
final class SoftwareUpdateControllerTests: XCTestCase {
    func testDefaultEnabledCheckPublishesUpToDate() async {
        let service = FakeSoftwareUpdateService(candidate: nil)
        let preferences = MemorySoftwareUpdatePreferences()
        let controller = makeController(
            service: service,
            preferences: preferences
        )

        XCTAssertTrue(controller.isEnabled)
        controller.start()
        await waitUntil { controller.isConfirmedUpToDate }

        let counts = await service.counts()
        XCTAssertEqual(counts.latest, 1)
        XCTAssertEqual(preferences.automaticUpdatesEnabled, nil)
        controller.setEnabled(false)
        XCTAssertEqual(preferences.automaticUpdatesEnabled, false)
    }

    func testPreparedUpdateWaitsForReservationThenRequestsTermination() async {
        let candidate = makeCandidate(version: "0.3.41", build: 42)
        let prepared = makePrepared(version: "0.3.41", build: 42)
        let service = FakeSoftwareUpdateService(
            candidate: candidate,
            prepared: prepared
        )
        let preferences = MemorySoftwareUpdatePreferences()
        var installationMayProceed = false
        var terminationRequested = false
        let controller = makeController(
            service: service,
            preferences: preferences,
            reserveInstallation: { installationMayProceed },
            requestTermination: { terminationRequested = true }
        )

        controller.start()
        await waitUntil {
            controller.phase == .waitingForIdle(version: "0.3.41")
        }
        XCTAssertFalse(terminationRequested)
        XCTAssertTrue(controller.hasAvailableUpdate)
        XCTAssertEqual(preferences.knownAvailableVersion, "0.3.41")
        XCTAssertEqual(preferences.knownAvailableBuild, 42)

        installationMayProceed = true
        await waitUntil { terminationRequested }

        XCTAssertEqual(controller.phase, .installing(version: "0.3.41"))
        let counts = await service.counts()
        XCTAssertEqual(counts.launch, 1)
    }

    func testDisablingPreservesKnownAvailableYellowState() async {
        let candidate = makeCandidate(version: "0.3.41", build: 42)
        let prepared = makePrepared(version: "0.3.41", build: 42)
        let service = FakeSoftwareUpdateService(
            candidate: candidate,
            prepared: prepared
        )
        let preferences = MemorySoftwareUpdatePreferences()
        let controller = makeController(
            service: service,
            preferences: preferences,
            reserveInstallation: { false }
        )

        controller.start()
        await waitUntil {
            controller.phase == .waitingForIdle(version: "0.3.41")
        }
        controller.setEnabled(false)
        await waitUntil { await service.counts().discard == 1 }

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.hasAvailableUpdate)
        XCTAssertEqual(controller.phase, .updateAvailable(version: "0.3.41"))
    }

    func testPersistedAvailableBuildStaysVisibleWhileDisabled() {
        let preferences = MemorySoftwareUpdatePreferences()
        preferences.automaticUpdatesEnabled = false
        preferences.knownAvailableVersion = "0.3.41"
        preferences.knownAvailableBuild = 42

        let controller = makeController(
            service: FakeSoftwareUpdateService(candidate: nil),
            preferences: preferences
        )

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.hasAvailableUpdate)
        XCTAssertEqual(controller.latestVersion, "0.3.41")
    }

    func testDisabledControllerStillChecksAndShowsAvailableWithoutDownloading() async {
        let candidate = makeCandidate(version: "0.3.41", build: 42)
        let service = FakeSoftwareUpdateService(candidate: candidate)
        let preferences = MemorySoftwareUpdatePreferences()
        preferences.automaticUpdatesEnabled = false
        let controller = makeController(
            service: service,
            preferences: preferences
        )

        controller.start()
        await waitUntil {
            controller.phase == .updateAvailable(version: "0.3.41")
        }

        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.hasAvailableUpdate)
        let counts = await service.counts()
        XCTAssertEqual(counts.latest, 1)
        XCTAssertEqual(counts.prepare, 0)
    }

    func testLateCancelledCycleCannotOverwriteANewerCheck() async {
        let service = RacingSoftwareUpdateService()
        let preferences = MemorySoftwareUpdatePreferences()
        let controller = SoftwareUpdateController(
            currentVersion: "0.3.40",
            currentBuild: 41,
            isConfigured: true,
            service: service,
            preferences: preferences,
            reserveInstallation: { false },
            releaseInstallationReservation: {},
            requestTermination: {},
            initialDelayNanoseconds: 0,
            checkIntervalNanoseconds: 3_600_000_000_000,
            idlePollNanoseconds: 1
        )

        controller.start()
        await service.waitForFirstRequest()
        controller.setEnabled(false)
        controller.setEnabled(true)
        await service.waitForSecondRequest()
        await waitUntil { controller.isConfirmedUpToDate }

        await service.resolveFirstWithFailure()
        for _ in 0..<30 { await Task.yield() }

        XCTAssertTrue(controller.isConfirmedUpToDate)
        XCTAssertNil(preferences.knownAvailableVersion)
        XCTAssertNil(preferences.knownAvailableBuild)
        await controller.shutdown()
    }

    func testCheckingKeepsAKnownAvailableUpdateVisible() async {
        let service = RacingSoftwareUpdateService()
        let preferences = MemorySoftwareUpdatePreferences()
        preferences.automaticUpdatesEnabled = false
        preferences.knownAvailableVersion = "0.3.41"
        preferences.knownAvailableBuild = 42
        let controller = SoftwareUpdateController(
            currentVersion: "0.3.40",
            currentBuild: 41,
            isConfigured: true,
            service: service,
            preferences: preferences,
            reserveInstallation: { false },
            releaseInstallationReservation: {},
            requestTermination: {},
            initialDelayNanoseconds: 0,
            checkIntervalNanoseconds: 3_600_000_000_000,
            idlePollNanoseconds: 1
        )

        controller.start()
        await service.waitForFirstRequest()

        XCTAssertEqual(controller.phase, .checking)
        XCTAssertTrue(controller.hasAvailableUpdate)
        await service.resolveFirstWithFailure()
        await controller.shutdown()
    }

    func testUnconfiguredControllerNeverStartsNetworkWork() async {
        let service = FakeSoftwareUpdateService(candidate: nil)
        let preferences = MemorySoftwareUpdatePreferences()
        let controller = SoftwareUpdateController(
            currentVersion: "0.3.40",
            currentBuild: 41,
            isConfigured: false,
            service: service,
            preferences: preferences,
            reserveInstallation: { false },
            releaseInstallationReservation: {},
            requestTermination: {},
            initialDelayNanoseconds: 0,
            checkIntervalNanoseconds: 1,
            idlePollNanoseconds: 1
        )

        controller.start()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(controller.phase, .unavailable)
        let counts = await service.counts()
        XCTAssertEqual(counts.latest, 0)
    }

    func testShutdownIsBoundedWhenAServiceIgnoresCancellation() async {
        let service = StuckSoftwareUpdateService()
        let preferences = MemorySoftwareUpdatePreferences()
        let controller = SoftwareUpdateController(
            currentVersion: "0.3.40",
            currentBuild: 41,
            isConfigured: true,
            service: service,
            preferences: preferences,
            reserveInstallation: { false },
            releaseInstallationReservation: {},
            requestTermination: {},
            initialDelayNanoseconds: 0,
            checkIntervalNanoseconds: 3_600_000_000_000,
            idlePollNanoseconds: 1,
            shutdownGraceNanoseconds: 1_000_000
        )

        controller.start()
        await service.waitForRequest()
        let startedAt = ProcessInfo.processInfo.systemUptime
        await controller.shutdown()
        let elapsed = ProcessInfo.processInfo.systemUptime - startedAt

        XCTAssertLessThan(elapsed, 0.5)
        await service.resolve()
        for _ in 0..<20 { await Task.yield() }
    }

    private func makeController(
        service: FakeSoftwareUpdateService,
        preferences: MemorySoftwareUpdatePreferences,
        reserveInstallation: @escaping @MainActor () -> Bool = { false },
        requestTermination: @escaping @MainActor () -> Void = {}
    ) -> SoftwareUpdateController {
        SoftwareUpdateController(
            currentVersion: "0.3.40",
            currentBuild: 41,
            isConfigured: true,
            service: service,
            preferences: preferences,
            reserveInstallation: reserveInstallation,
            releaseInstallationReservation: {},
            requestTermination: requestTermination,
            initialDelayNanoseconds: 0,
            checkIntervalNanoseconds: 3_600_000_000_000,
            idlePollNanoseconds: 1
        )
    }

    private func makeCandidate(
        version: String,
        build: Int
    ) -> SoftwareUpdateCandidate {
        SoftwareUpdateCandidate(
            version: version,
            build: build,
            assetName: "Codex Export \(version).zip",
            assetURL: URL(string: "https://github.com/example/repo/releases/download/v\(version)/app.zip")!,
            sha256: String(repeating: "ab", count: 32),
            size: 1_024
        )
    }

    private func makePrepared(
        version: String,
        build: Int
    ) -> PreparedSoftwareUpdate {
        let root = URL(fileURLWithPath: "/tmp/update-test")
        return PreparedSoftwareUpdate(
            version: version,
            build: build,
            workingDirectory: root,
            appBundleURL: root.appendingPathComponent("Codex Export.app")
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

@MainActor
private final class MemorySoftwareUpdatePreferences:
    SoftwareUpdatePreferenceStoring
{
    var automaticUpdatesEnabled: Bool?
    var knownAvailableVersion: String?
    var knownAvailableBuild: Int?
}

private actor FakeSoftwareUpdateService: SoftwareUpdateServicing {
    private let candidate: SoftwareUpdateCandidate?
    private let prepared: PreparedSoftwareUpdate
    private(set) var latestCallCount = 0
    private(set) var prepareCallCount = 0
    private(set) var launchCallCount = 0
    private(set) var discardCallCount = 0

    init(
        candidate: SoftwareUpdateCandidate?,
        prepared: PreparedSoftwareUpdate = PreparedSoftwareUpdate(
            version: "0.3.41",
            build: 42,
            workingDirectory: URL(fileURLWithPath: "/tmp/update-test"),
            appBundleURL: URL(fileURLWithPath: "/tmp/update-test/Codex Export.app")
        )
    ) {
        self.candidate = candidate
        self.prepared = prepared
    }

    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate? {
        latestCallCount += 1
        return candidate
    }

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate {
        prepareCallCount += 1
        return prepared
    }

    func launchInstaller(
        for update: PreparedSoftwareUpdate
    ) async throws {
        launchCallCount += 1
    }

    func discard(_ update: PreparedSoftwareUpdate) async {
        discardCallCount += 1
    }

    func counts() -> (latest: Int, prepare: Int, launch: Int, discard: Int) {
        (latestCallCount, prepareCallCount, launchCallCount, discardCallCount)
    }
}

private actor RacingSoftwareUpdateService: SoftwareUpdateServicing {
    private var callCount = 0
    private var firstContinuation:
        CheckedContinuation<SoftwareUpdateCandidate?, Error>?
    private var firstRequestWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondRequestWaiters: [CheckedContinuation<Void, Never>] = []

    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate? {
        callCount += 1
        if callCount == 1 {
            let waiters = firstRequestWaiters
            firstRequestWaiters = []
            waiters.forEach { $0.resume() }
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
        let waiters = secondRequestWaiters
        secondRequestWaiters = []
        waiters.forEach { $0.resume() }
        return nil
    }

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate {
        fatalError("A stale cycle must not prepare an update")
    }

    func launchInstaller(for update: PreparedSoftwareUpdate) async throws {
        fatalError("A stale cycle must not install an update")
    }

    func discard(_ update: PreparedSoftwareUpdate) async {}

    func waitForFirstRequest() async {
        if callCount >= 1 { return }
        await withCheckedContinuation { firstRequestWaiters.append($0) }
    }

    func waitForSecondRequest() async {
        if callCount >= 2 { return }
        await withCheckedContinuation { secondRequestWaiters.append($0) }
    }

    func resolveFirstWithFailure() {
        firstContinuation?.resume(throwing: TestUpdateError.staleFailure)
        firstContinuation = nil
    }
}

private actor StuckSoftwareUpdateService: SoftwareUpdateServicing {
    private var continuation: CheckedContinuation<SoftwareUpdateCandidate?, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func latestUpdate(
        currentVersion: String,
        currentBuild: Int
    ) async throws -> SoftwareUpdateCandidate? {
        let waiters = requestWaiters
        requestWaiters = []
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation = $0 }
    }

    func prepare(
        _ candidate: SoftwareUpdateCandidate
    ) async throws -> PreparedSoftwareUpdate {
        fatalError("The stuck check must not prepare an update")
    }

    func launchInstaller(for update: PreparedSoftwareUpdate) async throws {
        fatalError("The stuck check must not install an update")
    }

    func discard(_ update: PreparedSoftwareUpdate) async {}

    func waitForRequest() async {
        if continuation != nil { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resolve() {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}

private enum TestUpdateError: Error {
    case staleFailure
}
