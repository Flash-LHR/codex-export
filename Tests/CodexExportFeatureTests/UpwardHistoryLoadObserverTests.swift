import AppKit
import XCTest
@testable import CodexExportFeature

@MainActor
final class UpwardHistoryLoadObserverTests: XCTestCase {
    func testLiveScrollTriggersOnlyOncePerGesture() {
        let fixture = makeFixture()
        defer { fixture.monitor.stopObserving() }
        var triggerCount = 0
        fixture.monitor.onApproachingTop = { triggerCount += 1 }
        fixture.monitor.updateLoadState(
            isEnabled: true,
            canQueueWhileBusy: false
        )

        post(NSScrollView.willStartLiveScrollNotification, for: fixture.scrollView)
        scroll(fixture.scrollView, to: 600)
        post(NSScrollView.didLiveScrollNotification, for: fixture.scrollView)
        scroll(fixture.scrollView, to: 500)
        post(NSScrollView.didLiveScrollNotification, for: fixture.scrollView)

        XCTAssertEqual(triggerCount, 1)

        post(NSScrollView.didEndLiveScrollNotification, for: fixture.scrollView)
        scroll(fixture.scrollView, to: 400)
        post(NSScrollView.willStartLiveScrollNotification, for: fixture.scrollView)
        scroll(fixture.scrollView, to: 300)
        post(NSScrollView.didLiveScrollNotification, for: fixture.scrollView)

        XCTAssertEqual(triggerCount, 2)
    }

    func testNearTopDemandWhileBusyReplaysOnceWhenLoadingFinishes() async {
        let fixture = makeFixture()
        defer { fixture.monitor.stopObserving() }
        let replayed = expectation(description: "deferred history load replayed")
        var triggerCount = 0
        fixture.monitor.onApproachingTop = {
            triggerCount += 1
            replayed.fulfill()
        }
        fixture.monitor.updateLoadState(
            isEnabled: false,
            canQueueWhileBusy: true
        )

        post(NSScrollView.willStartLiveScrollNotification, for: fixture.scrollView)
        scroll(fixture.scrollView, to: 600)
        post(NSScrollView.didLiveScrollNotification, for: fixture.scrollView)
        XCTAssertEqual(triggerCount, 0)

        fixture.monitor.updateLoadState(
            isEnabled: true,
            canQueueWhileBusy: true
        )
        await fulfillment(of: [replayed], timeout: 1)
        for _ in 0..<5 { await Task.yield() }

        XCTAssertEqual(triggerCount, 1)
    }

    private func makeFixture() -> (
        scrollView: NSScrollView,
        monitor: UpwardHistoryLoadMonitorView
    ) {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 200)
        )
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 2_000)
        )
        let monitor = UpwardHistoryLoadMonitorView(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1)
        )
        documentView.addSubview(monitor)
        scrollView.documentView = documentView
        scroll(scrollView, to: 1_200)
        monitor.attachToEnclosingScrollViewIfNeeded()
        return (scrollView, monitor)
    }

    private func scroll(_ scrollView: NSScrollView, to y: CGFloat) {
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func post(
        _ name: Notification.Name,
        for scrollView: NSScrollView
    ) {
        NotificationCenter.default.post(name: name, object: scrollView)
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}
