import Foundation
import XCTest
@testable import CodexExportCore

final class OrderedLineFramerTests: XCTestCase {
    func testLargeJSONLineSurvivesManyPipeSizedChunks() throws {
        let payload = String(repeating: "费马abc123", count: 20_000)
        let line = try JSONSerialization.data(withJSONObject: [
            "id": 7,
            "result": ["payload": payload],
        ])
        var wire = line
        wire.append(0x0A)

        let framer = OrderedLineFramer()
        var output: [Data] = []
        var offset = 0
        let chunkSizes = [1, 16_383, 7, 32_768, 101, 8_191]
        var chunkIndex = 0
        while offset < wire.count {
            let end = min(wire.count, offset + chunkSizes[chunkIndex % chunkSizes.count])
            output.append(contentsOf: framer.append(wire.subdata(in: offset..<end)))
            offset = end
            chunkIndex += 1
        }

        XCTAssertEqual(output, [line])
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: output[0]) as? [String: Any]
        )
        let result = try XCTUnwrap(decoded["result"] as? [String: Any])
        XCTAssertEqual(result["payload"] as? String, payload)
    }

    func testMultipleLinesAndTrailingPartialAreFramedExactlyOnce() {
        let framer = OrderedLineFramer()

        XCTAssertEqual(framer.append(Data("first".utf8)), [])
        XCTAssertEqual(
            framer.append(Data(" line\nsecond\nthird".utf8)),
            [Data("first line".utf8), Data("second".utf8)]
        )
        XCTAssertEqual(
            framer.append(Data(" line\n".utf8)),
            [Data("third line".utf8)]
        )
    }
}
