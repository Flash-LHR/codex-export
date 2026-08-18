import XCTest
@testable import CodexExportApp

@MainActor
final class DeferredApplicationTerminationTests: XCTestCase {
    func testTerminationRunsOnlyAfterTheRequestingActorJobReturns() async {
        let completion = expectation(description: "termination was dispatched")
        let recorder = TerminationRecorder()

        recorder.events.append("before")
        DeferredApplicationTermination.schedule {
            recorder.events.append("terminate")
            completion.fulfill()
        }
        recorder.events.append("after")

        XCTAssertEqual(recorder.events, ["before", "after"])
        await fulfillment(of: [completion], timeout: 1)
        XCTAssertEqual(recorder.events, ["before", "after", "terminate"])
    }
}

@MainActor
private final class TerminationRecorder {
    var events: [String] = []
}
