/// Calculates how far ahead the message list should request older history.
///
/// The base distance is roughly two viewports. Faster real scrolling adds up
/// to another two viewports of lead time, while fixed bounds keep a small
/// popover from fetching history merely because it was laid out.
enum HistoryPrefetchPolicy {
    static func leadDistance(
        viewportHeight: Double,
        upwardVelocity: Double
    ) -> Double {
        let viewport = max(1, viewportHeight)
        let base = min(1_400, max(700, viewport * 2))
        let velocityLead = min(1_000, max(0, upwardVelocity) * 0.35)
        return min(2_400, base + velocityLead)
    }

    static func projectedDistance(
        currentDistance: Double,
        scrollingDelta: Double,
        hasPreciseDeltas: Bool
    ) -> Double {
        let upwardDelta = max(0, scrollingDelta)
        let normalizedDelta = hasPreciseDeltas
            ? upwardDelta
            : upwardDelta * 40
        return max(0, currentDistance - normalizedDelta)
    }
}
