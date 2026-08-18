import AppKit
import XCTest
@testable import CodexExportApp

@MainActor
final class ApplicationTerminationCoordinatorTests: XCTestCase {
    func testFirstRequestCancelsThenRetryTerminatesImmediately() async {
        let coordinator = ApplicationTerminationCoordinator()
        let preparation = AsyncPreparationGate()
        let retry = expectation(description: "termination was retried")

        let firstReply = coordinator.reply(
            prepare: { await preparation.wait() },
            retry: { retry.fulfill() }
        )
        XCTAssertEqual(firstReply.rawValue, NSApplication.TerminateReply.terminateCancel.rawValue)

        await Task.yield()
        await preparation.finish()
        await fulfillment(of: [retry], timeout: 1)

        let secondReply = coordinator.reply(
            prepare: { XCTFail("preparation must run exactly once") },
            retry: { XCTFail("an accepted retry must not schedule again") }
        )
        XCTAssertEqual(secondReply.rawValue, NSApplication.TerminateReply.terminateNow.rawValue)
    }

    func testRepeatedRequestsDuringPreparationDoNotStartDuplicateCleanup() async {
        let coordinator = ApplicationTerminationCoordinator()
        let preparation = AsyncPreparationGate()
        let recorder = PreparationRecorder()
        let retry = expectation(description: "termination was retried")

        let firstReply = coordinator.reply(
            prepare: {
                recorder.count += 1
                await preparation.wait()
            },
            retry: { retry.fulfill() }
        )
        let repeatedReply = coordinator.reply(
            prepare: { recorder.count += 1 },
            retry: { XCTFail("only the first retry closure is retained") }
        )

        XCTAssertEqual(firstReply.rawValue, NSApplication.TerminateReply.terminateCancel.rawValue)
        XCTAssertEqual(repeatedReply.rawValue, NSApplication.TerminateReply.terminateCancel.rawValue)
        await Task.yield()
        XCTAssertEqual(recorder.count, 1)

        await preparation.finish()
        await fulfillment(of: [retry], timeout: 1)
        XCTAssertEqual(recorder.count, 1)
    }
}

@MainActor
private final class PreparationRecorder {
    var count = 0
}

private actor AsyncPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    func wait() async {
        if isFinished { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish() {
        isFinished = true
        continuation?.resume()
        continuation = nil
    }
}
