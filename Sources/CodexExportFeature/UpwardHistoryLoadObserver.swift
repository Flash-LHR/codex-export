import AppKit
import SwiftUI

/// Bridges SwiftUI's scroll view to AppKit's live-scroll notifications. A page
/// is requested only after real upward browsing intent. If another page
/// is already in flight, one near-top request may be held until it finishes;
/// initial layout, programmatic scrollTo calls, and prepending rows never create
/// that pending demand themselves.
struct UpwardHistoryLoadObserver: NSViewRepresentable {
    let isEnabled: Bool
    let canQueueWhileBusy: Bool
    let onUserScroll: () -> Void
    let onApproachingTop: () -> Void

    func makeNSView(context: Context) -> UpwardHistoryLoadMonitorView {
        let view = UpwardHistoryLoadMonitorView()
        view.onUserScroll = onUserScroll
        view.onApproachingTop = onApproachingTop
        view.updateLoadState(
            isEnabled: isEnabled,
            canQueueWhileBusy: canQueueWhileBusy
        )
        return view
    }

    func updateNSView(
        _ nsView: UpwardHistoryLoadMonitorView,
        context: Context
    ) {
        nsView.onUserScroll = onUserScroll
        nsView.onApproachingTop = onApproachingTop
        nsView.attachToEnclosingScrollViewIfNeeded()
        nsView.updateLoadState(
            isEnabled: isEnabled,
            canQueueWhileBusy: canQueueWhileBusy
        )
    }

    static func dismantleNSView(
        _ nsView: UpwardHistoryLoadMonitorView,
        coordinator: ()
    ) {
        nsView.stopObserving()
    }
}

final class UpwardHistoryLoadMonitorView: NSView {
    var onUserScroll: (() -> Void)?
    var onApproachingTop: (() -> Void)?

    private var isEnabled = false
    private var canQueueWhileBusy = false
    private weak var observedScrollView: NSScrollView?
    private var localScrollMonitor: Any?
    private var wheelGestureResetTimer: Timer?
    private var previousTopDistance: CGFloat?
    private var previousScrollSampleTime: TimeInterval?
    private var smoothedUpwardVelocity: CGFloat = 0
    private var isLiveScrollActive = false
    private var triggeredDuringLiveScroll = false
    private var triggeredDuringWheelGesture = false
    private var deferredTriggerAfterBusy = false
    private var deferredReplayConsumedForCurrentGesture = false
    private var deferredCheckGeneration = 0

    func updateLoadState(
        isEnabled newIsEnabled: Bool,
        canQueueWhileBusy newCanQueueWhileBusy: Bool
    ) {
        guard isEnabled != newIsEnabled
                || canQueueWhileBusy != newCanQueueWhileBusy else {
            return
        }
        let becameEnabled = !isEnabled && newIsEnabled
        isEnabled = newIsEnabled
        canQueueWhileBusy = newCanQueueWhileBusy
        deferredCheckGeneration += 1

        if !canQueueWhileBusy {
            deferredTriggerAfterBusy = false
        } else if becameEnabled, deferredTriggerAfterBusy {
            scheduleDeferredTriggerCheck(
                generation: deferredCheckGeneration
            )
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        attachToEnclosingScrollViewIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopObserving()
        } else {
            attachToEnclosingScrollViewIfNeeded()
        }
    }

    func attachToEnclosingScrollViewIfNeeded() {
        guard let scrollView = enclosingScrollView else { return }
        guard observedScrollView !== scrollView else { return }

        stopObserving()
        observedScrollView = scrollView
        previousTopDistance = topDistance(in: scrollView)

        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(willStartLiveScroll(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(didLiveScroll(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        center.addObserver(
            self,
            selector: #selector(didEndLiveScroll(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .scrollWheel
        ) { [weak self] event in
            self?.handleScrollWheel(event)
            return event
        }
    }

    func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        if let localScrollMonitor {
            NSEvent.removeMonitor(localScrollMonitor)
            self.localScrollMonitor = nil
        }
        observedScrollView = nil
        previousTopDistance = nil
        previousScrollSampleTime = nil
        smoothedUpwardVelocity = 0
        wheelGestureResetTimer?.invalidate()
        wheelGestureResetTimer = nil
        isLiveScrollActive = false
        triggeredDuringLiveScroll = false
        triggeredDuringWheelGesture = false
        deferredTriggerAfterBusy = false
        deferredReplayConsumedForCurrentGesture = false
        deferredCheckGeneration += 1
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else { return }
        onUserScroll?()
        previousTopDistance = topDistance(in: scrollView)
        previousScrollSampleTime = ProcessInfo.processInfo.systemUptime
        smoothedUpwardVelocity = 0
        isLiveScrollActive = true
        triggeredDuringLiveScroll = false
        deferredReplayConsumedForCurrentGesture = false
    }

    @objc private func didLiveScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView,
              let currentDistance = topDistance(in: scrollView) else {
            return
        }

        let previousDistance = previousTopDistance ?? currentDistance
        previousTopDistance = currentDistance
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = max(
            1.0 / 240.0,
            min(0.25, now - (previousScrollSampleTime ?? now))
        )
        previousScrollSampleTime = now
        let upwardTravel = previousDistance - currentDistance

        if upwardTravel > 0.5 {
            let observedVelocity = upwardTravel / elapsed
            smoothedUpwardVelocity = smoothedUpwardVelocity == 0
                ? observedVelocity
                : (smoothedUpwardVelocity * 0.65) + (observedVelocity * 0.35)
        } else if upwardTravel < -0.5 {
            smoothedUpwardVelocity = 0
            deferredTriggerAfterBusy = false
        }

        guard upwardTravel > 0.5 else { return }
        let threshold = leadDistance(in: scrollView)
        guard currentDistance <= threshold else { return }

        if !isEnabled {
            if canQueueWhileBusy,
               !deferredReplayConsumedForCurrentGesture {
                deferredTriggerAfterBusy = true
            }
            return
        }

        guard !triggeredDuringLiveScroll,
              !triggeredDuringWheelGesture,
              currentDistance < previousDistance - 0.5 else {
            return
        }

        triggeredDuringLiveScroll = true
        onApproachingTop?()
    }

    @objc private func didEndLiveScroll(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else { return }
        previousTopDistance = topDistance(in: scrollView)
        previousScrollSampleTime = nil
        smoothedUpwardVelocity = 0
        isLiveScrollActive = false
        triggeredDuringLiveScroll = false
        triggeredDuringWheelGesture = false
        deferredReplayConsumedForCurrentGesture = false
        wheelGestureResetTimer?.invalidate()
        wheelGestureResetTimer = nil
    }

    private func handleScrollWheel(_ event: NSEvent) {
        guard let scrollView = observedScrollView,
              event.window === window,
              let currentDistance = topDistance(in: scrollView) else {
            return
        }

        let location = scrollView.convert(event.locationInWindow, from: nil)
        guard scrollView.bounds.contains(location) else { return }
        onUserScroll?()
        scheduleWheelGestureReset(in: scrollView)

        guard event.scrollingDeltaY != 0 else { return }
        guard event.scrollingDeltaY > 0 else {
            smoothedUpwardVelocity = 0
            deferredTriggerAfterBusy = false
            return
        }

        let projectedDistance = CGFloat(
            HistoryPrefetchPolicy.projectedDistance(
                currentDistance: Double(currentDistance),
                scrollingDelta: Double(event.scrollingDeltaY),
                hasPreciseDeltas: event.hasPreciseScrollingDeltas
            )
        )
        guard projectedDistance <= leadDistance(in: scrollView) else { return }

        if !isEnabled {
            if canQueueWhileBusy,
               !deferredReplayConsumedForCurrentGesture {
                deferredTriggerAfterBusy = true
            }
            return
        }

        guard !triggeredDuringLiveScroll,
              !triggeredDuringWheelGesture else {
            return
        }

        // The local monitor also covers a wheel/trackpad gesture made while
        // already resting at the hard top, where the clip view cannot move and
        // therefore emits no didLiveScroll notification.
        triggeredDuringWheelGesture = true
        onApproachingTop?()
    }

    private func scheduleDeferredTriggerCheck(generation: Int) {
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.deferredCheckGeneration == generation,
                      self.isEnabled,
                      self.deferredTriggerAfterBusy,
                      let scrollView = self.observedScrollView,
                      let currentDistance = self.topDistance(in: scrollView) else {
                    return
                }

                self.deferredTriggerAfterBusy = false
                // The request may have taken long enough for the earlier
                // velocity estimate to become stale. Re-enable checks use the
                // steady two-viewport watermark and only continue if the user
                // is still genuinely close to the newly laid-out top.
                guard currentDistance <= self.leadDistance(
                    in: scrollView,
                    includeVelocity: false
                ) else {
                    return
                }

                self.deferredReplayConsumedForCurrentGesture = true
                self.triggeredDuringWheelGesture = true
                self.scheduleWheelGestureReset(in: scrollView)
                self.onApproachingTop?()
            }
        }
    }

    private func leadDistance(
        in scrollView: NSScrollView,
        includeVelocity: Bool = true
    ) -> CGFloat {
        CGFloat(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: Double(scrollView.contentView.bounds.height),
                upwardVelocity: includeVelocity
                    ? Double(smoothedUpwardVelocity)
                    : 0
            )
        )
    }

    private func scheduleWheelGestureReset(in scrollView: NSScrollView) {
        wheelGestureResetTimer?.invalidate()
        let timer = Timer(timeInterval: 0.22, repeats: false) { [weak self, weak scrollView] _ in
            Task { @MainActor [weak self, weak scrollView] in
                guard let self else { return }
                // A scroll-wheel event can be followed by a longer AppKit
                // live-scroll lifecycle (including momentum or scrollbar
                // dragging). Do not reopen the one-replay allowance until that
                // lifecycle really ends. At the hard top no lifecycle starts,
                // so this quiet-period reset still handles discrete wheels.
                if !self.isLiveScrollActive {
                    self.triggeredDuringLiveScroll = false
                    self.triggeredDuringWheelGesture = false
                    self.deferredReplayConsumedForCurrentGesture = false
                    self.smoothedUpwardVelocity = 0
                }
                if let scrollView {
                    self.previousTopDistance = self.topDistance(in: scrollView)
                }
                self.wheelGestureResetTimer = nil
            }
        }
        wheelGestureResetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func topDistance(in scrollView: NSScrollView) -> CGFloat? {
        guard let documentView = scrollView.documentView else { return nil }
        let visible = scrollView.documentVisibleRect
        if documentView.isFlipped {
            return visible.minY - documentView.bounds.minY
        }
        return documentView.bounds.maxY - visible.maxY
    }
}
