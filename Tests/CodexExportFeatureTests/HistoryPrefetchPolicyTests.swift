import XCTest
@testable import CodexExportFeature

final class HistoryPrefetchPolicyTests: XCTestCase {
    func testLeadDistanceStartsAroundTwoViewports() {
        XCTAssertEqual(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: 500,
                upwardVelocity: 0
            ),
            1_000
        )
        XCTAssertEqual(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: 200,
                upwardVelocity: 0
            ),
            700
        )
        XCTAssertEqual(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: 900,
                upwardVelocity: 0
            ),
            1_400
        )
    }

    func testFastScrollingAddsBoundedLookahead() {
        XCTAssertEqual(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: 500,
                upwardVelocity: 1_000
            ),
            1_350
        )
        XCTAssertEqual(
            HistoryPrefetchPolicy.leadDistance(
                viewportHeight: 700,
                upwardVelocity: 10_000
            ),
            2_400
        )
    }

    func testWheelProjectionNormalizesDiscreteAndPreciseDevices() {
        XCTAssertEqual(
            HistoryPrefetchPolicy.projectedDistance(
                currentDistance: 1_000,
                scrollingDelta: 120,
                hasPreciseDeltas: true
            ),
            880
        )
        XCTAssertEqual(
            HistoryPrefetchPolicy.projectedDistance(
                currentDistance: 1_000,
                scrollingDelta: 3,
                hasPreciseDeltas: false
            ),
            880
        )
        XCTAssertEqual(
            HistoryPrefetchPolicy.projectedDistance(
                currentDistance: 1_000,
                scrollingDelta: -50,
                hasPreciseDeltas: true
            ),
            1_000
        )
    }
}
