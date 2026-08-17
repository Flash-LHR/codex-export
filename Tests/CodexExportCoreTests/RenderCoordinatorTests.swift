import XCTest
@testable import CodexExportCore

@MainActor
final class RenderCoordinatorTests: XCTestCase {
    func testFIFOQueuedCancellationDoesNotDelayTheNextRender() async throws {
        let fifo = RenderFIFO()
        var events: [String] = []
        var releaseActive: CheckedContinuation<Void, Never>?

        let active = Task { @MainActor in
            try await fifo.withPermit {
                events.append("active-start")
                await withCheckedContinuation { releaseActive = $0 }
                events.append("active-end")
            }
        }
        await waitUntil { releaseActive != nil }

        let cancelled = Task { @MainActor in
            try await fifo.withPermit {
                events.append("cancelled-start")
            }
        }
        let survivor = Task { @MainActor in
            try await fifo.withPermit {
                events.append("survivor-start")
            }
        }
        await waitUntil { fifo.queuedCount == 2 }

        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("A cancelled queued render must not acquire the permit")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(fifo.queuedCount, 1)

        releaseActive?.resume()
        try await active.value
        try await survivor.value
        XCTAssertEqual(events, ["active-start", "active-end", "survivor-start"])
    }

    func testActiveCancellationWaitsForWebKitBeforePassingThePermit() async throws {
        let fifo = RenderFIFO()
        let scheduler = ManualRenderTimeoutScheduler()
        let coordinator = WebOperationCoordinator(scheduler: scheduler)
        var firstCompletion: (@Sendable (Result<Int, Error>) -> Void)?
        var secondCompletion: (@Sendable (Result<Int, Error>) -> Void)?

        let first = Task { @MainActor in
            try await fifo.withPermit {
                try await coordinator.perform(timeoutError: TestError.timeout) {
                    firstCompletion = $0
                }
            }
        }
        await waitUntil { firstCompletion != nil }

        let second = Task { @MainActor in
            try await fifo.withPermit {
                try await coordinator.perform(timeoutError: TestError.timeout) {
                    secondCompletion = $0
                }
            }
        }
        await waitUntil { fifo.queuedCount == 1 }

        first.cancel()
        await Task.yield()
        XCTAssertNil(secondCompletion)
        XCTAssertEqual(coordinator.pendingCount, 1)

        firstCompletion?(.success(1))
        do {
            _ = try await first.value
            XCTFail("The active caller must observe cancellation after settling")
        } catch is CancellationError {
            // Expected.
        }

        await waitUntil { secondCompletion != nil }
        secondCompletion?(.success(2))
        let secondValue = try await second.value
        XCTAssertEqual(secondValue, 2)
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertTrue(scheduler.tokens.allSatisfy(\.isCancelled))
    }

    func testTimeoutWinsOnceAndIgnoresALateCallback() async throws {
        let scheduler = ManualRenderTimeoutScheduler()
        let coordinator = WebOperationCoordinator(scheduler: scheduler)
        var completion: (@Sendable (Result<Int, Error>) -> Void)?

        let task = Task { @MainActor in
            try await coordinator.perform(timeoutError: TestError.timeout) {
                completion = $0
            }
        }
        await waitUntil { completion != nil && scheduler.pendingCount == 1 }
        scheduler.fireNext()

        do {
            _ = try await task.value
            XCTFail("Expected the manual timeout")
        } catch let error as TestError {
            XCTAssertEqual(error, .timeout)
        }
        XCTAssertEqual(coordinator.pendingCount, 0)
        XCTAssertTrue(scheduler.tokens.allSatisfy(\.isCancelled))

        completion?(.success(42))
        completion?(.failure(TestError.lateCallback))
        await Task.yield()
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    func testCancellationFollowedByTimeoutReturnsCancellation() async throws {
        let scheduler = ManualRenderTimeoutScheduler()
        let coordinator = WebOperationCoordinator(scheduler: scheduler)
        var completionInstalled = false

        let task = Task { @MainActor in
            try await coordinator.perform(timeoutError: TestError.timeout) {
                _ in completionInstalled = true
            } as Int
        }
        await waitUntil { completionInstalled && scheduler.pendingCount == 1 }
        task.cancel()
        XCTAssertEqual(coordinator.pendingCount, 1)

        // Deliberately settle the timeout before the MainActor cancellation
        // routing task can run. Cancellation must still win this race.
        scheduler.fireNext()
        do {
            _ = try await task.value
            XCTFail("Cancellation must take precedence over timeout")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(coordinator.pendingCount, 0)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
}

private enum TestError: Error, Equatable {
    case timeout
    case lateCallback
}

@MainActor
private final class ManualRenderTimeoutToken: RenderTimeoutToken {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

@MainActor
private final class ManualRenderTimeoutScheduler: RenderTimeoutScheduling {
    private struct Entry {
        let token: ManualRenderTimeoutToken
        let action: @MainActor @Sendable () -> Void
    }

    private var entries: [Entry] = []
    private(set) var tokens: [ManualRenderTimeoutToken] = []

    var pendingCount: Int {
        entries.count { !$0.token.isCancelled }
    }

    func schedule(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> any RenderTimeoutToken {
        let token = ManualRenderTimeoutToken()
        tokens.append(token)
        entries.append(Entry(token: token, action: action))
        return token
    }

    func fireNext() {
        guard let index = entries.firstIndex(where: { !$0.token.isCancelled }) else {
            return
        }
        let entry = entries.remove(at: index)
        entry.action()
    }
}
