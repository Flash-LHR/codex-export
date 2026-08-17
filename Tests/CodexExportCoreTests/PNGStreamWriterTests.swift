import XCTest
@testable import CodexExportCore

final class PNGStreamWriterTests: XCTestCase {
    func testWritesAValidOnePixelPNGAndFinishesIdempotently() throws {
        let writer = try PNGStreamWriter(width: 1, height: 1, maximumBytes: 1_024)
        try writer.writeScanline([0, 0x11, 0x22, 0x33, 0xFF])
        let first = try writer.finish()
        let second = try writer.finish()

        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        XCTAssertEqual(readBigEndian(first[16..<20]), 1)
        XCTAssertEqual(readBigEndian(first[20..<24]), 1)
        XCTAssertThrowsError(try writer.writeScanline([0, 0, 0, 0, 0])) {
            XCTAssertEqual($0 as? WebMarkdownRendererError, .pngEncodingFailed)
        }
    }

    func testEncodedByteLimitIsEnforcedBeforeGrowingTheBuffer() throws {
        XCTAssertThrowsError(
            try PNGStreamWriter(width: 1, height: 1, maximumBytes: 32)
        ) { error in
            guard case .encodedImageTooLarge(maximumBytes: 32) =
                    error as? WebMarkdownRendererError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func readBigEndian(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
