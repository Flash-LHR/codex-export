import AppKit
import CoreGraphics
import XCTest
@testable import CodexExportCore

@MainActor
final class WebMarkdownRendererTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["CODEX_EXPORT_RUN_WEB_TESTS"] == "1" else {
            throw XCTSkip("WKWebView integration tests require an application run loop; use the packaged-app probe.")
        }
    }

    func testRendersGFMTableAndFourMathDelimiterStyles() async throws {
        let result = try await WebMarkdownRenderer(
            resourceDirectory: testRendererResourceDirectory()
        ).render(messages: [
            RenderMessage(
                role: .assistant,
                text: #"""
                行内公式 $E=mc^2$ 与 \(a^2+b^2=c^2\)。

                $$
                \sum_{i=1}^{n} i=\frac{n(n+1)}{2}
                $$

                \[
                \begin{aligned} f(x)&=x^2\\g(x)&=\sqrt{x}\end{aligned}
                \]

                | 中文名称 | 数值 | 说明 |
                | :--- | ---: | :---: |
                | 公式 | $\frac{1}{2}$ | 很长的单元格会按照真实列宽自动换行，而不是依赖等宽字符填充 |
                | 条件概率 | $P(A|B)$ | 公式内的竖线不能拆成新列 |
                | 转义管道 | `a|b` | **粗体内容** |
                """#
            )
        ])

        XCTAssertEqual(result.width, 1_080)
        XCTAssertGreaterThan(result.height, 400)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result.pngData))
        XCTAssertEqual(bitmap.pixelsWide, 1_080)
        XCTAssertEqual(bitmap.pixelsHigh, result.height)
        XCTAssertTrue(imageHasNonBackgroundInk(bitmap))

        if let path = ProcessInfo.processInfo.environment["CODEX_EXPORT_WEB_PREVIEW_PATH"] {
            try result.pngData.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    func testNonIntegralFinalBandKeepsTopAndBottomInOrder() async throws {
        let middle = Array(repeating: "middle marker line", count: 125)
            .joined(separator: "\n\n")
        let result = try await WebMarkdownRenderer(
            resourceDirectory: testRendererResourceDirectory()
        ).render(messages: [
            RenderMessage(
                role: .assistant,
                text: "TOP_RED_MARKER\n\n\(middle)\n\nBOTTOM_BLUE_MARKER"
            )
        ])
        XCTAssertGreaterThan(result.height, 2_048)
        XCTAssertNotEqual(result.height % 2_048, 0)

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result.pngData))
        XCTAssertTrue(hasInk(bitmap, yRange: 60..<min(500, bitmap.pixelsHigh)))
        XCTAssertTrue(hasInk(
            bitmap,
            yRange: max(0, bitmap.pixelsHigh - 500)..<bitmap.pixelsHigh
        ))
    }

    func testUserHTMLAndScriptStayInert() async throws {
        let result = try await WebMarkdownRenderer(
            resourceDirectory: testRendererResourceDirectory()
        ).render(messages: [
            RenderMessage(
                role: .user,
                text: #"<script>document.body.innerHTML='owned'</script><img src='https://example.invalid/x'>literal"#
            )
        ])
        XCTAssertGreaterThan(result.height, 0)
        XCTAssertTrue(imageHasNonBackgroundInk(
            try XCTUnwrap(NSBitmapImageRep(data: result.pngData))
        ))
    }

    func testTaskMarkersBecomeVisualCheckboxes() async throws {
        let result = try await WebMarkdownRenderer(
            resourceDirectory: testRendererResourceDirectory()
        ).render(messages: [
            RenderMessage(role: .user, text: "- [x] 完成\n- [ ] 待办")
        ])
        XCTAssertGreaterThan(result.height, 0)
    }

    func testUltraTallExportIsOneExactHeightPNG() async throws {
        let paragraph = """
        ## 标题

        **粗体中文**与公式 $\\frac{a}{b}$。

        | 项目 | 数值 |
        | --- | ---: |
        | 高度 | 100000 |
        """
        let messages = (0..<300).map { index in
            RenderMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                text: paragraph
            )
        }
        let result = try await WebMarkdownRenderer(
            resourceDirectory: testRendererResourceDirectory()
        ).render(messages: messages)
        XCTAssertGreaterThan(result.height, WebMarkdownRenderer.warningHeight)
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(pngDimensions(result.pngData)?.width, 1_080)
        XCTAssertEqual(pngDimensions(result.pngData)?.height, result.height)
    }

    private func imageHasNonBackgroundInk(_ bitmap: NSBitmapImageRep) -> Bool {
        hasInk(bitmap, yRange: 0..<bitmap.pixelsHigh)
    }

    private func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24,
              Array(data.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else {
            return nil
        }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return (Int(width), Int(height))
    }

    private func hasInk(_ bitmap: NSBitmapImageRep, yRange: Range<Int>) -> Bool {
        let stride = 8
        for y in Swift.stride(from: yRange.lowerBound, to: yRange.upperBound, by: stride) {
            for x in Swift.stride(from: 72, to: bitmap.pixelsWide - 72, by: stride) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                let lightest = max(color.redComponent, color.greenComponent, color.blueComponent)
                let darkest = min(color.redComponent, color.greenComponent, color.blueComponent)
                if lightest < 0.72 || lightest - darkest > 0.12 {
                    return true
                }
            }
        }
        return false
    }
}

@MainActor
final class WebPDFRasterTests: XCTestCase {
    func testPagedPDFStitchesExactHeightAndTopToBottomDirectionAcrossBands() async throws {
        let pageHeight = 2_501
        let pdfData = try makeMarkerPDF(pageHeight: pageHeight, pageCount: 2)
        var progressValues: [Double] = []
        let pngData = try await WebMarkdownRenderer.rasterizePDF(
            pdfData,
            expectedHeight: pageHeight * 2,
            progress: { progressValues.append($0) }
        )

        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: pngData))
        XCTAssertEqual(bitmap.pixelsWide, 1_080)
        XCTAssertEqual(bitmap.pixelsHigh, pageHeight * 2)
        XCTAssertColor(bitmap, x: 8, y: 8, isNear: (1, 0, 0))
        XCTAssertColor(bitmap, x: 8, y: pageHeight - 8, isNear: (0, 1, 0))
        XCTAssertColor(bitmap, x: 8, y: pageHeight + 8, isNear: (1, 1, 0))
        XCTAssertColor(bitmap, x: 8, y: (pageHeight * 2) - 8, isNear: (0, 0, 1))
        XCTAssertColor(bitmap, x: 104, y: 2_047, isNear: (0, 0, 0))
        XCTAssertColor(bitmap, x: 104, y: 2_048, isNear: (0, 0, 0))
        XCTAssertEqual(try XCTUnwrap(progressValues.last), 1, accuracy: 0.000_001)
        XCTAssertEqual(progressValues, progressValues.sorted())
    }

    func testPagedPDFRejectsAStitchedHeightMismatch() async throws {
        let pdfData = try makeMarkerPDF(pageHeight: 2_501, pageCount: 2)
        do {
            _ = try await WebMarkdownRenderer.rasterizePDF(
                pdfData,
                expectedHeight: 5_001
            )
            XCTFail("Expected an exact-height validation error")
        } catch let error as WebMarkdownRendererError {
            XCTAssertEqual(error, .invalidSnapshot)
        }
    }

    private func makeMarkerPDF(pageHeight: Int, pageCount: Int) throws -> Data {
        let output = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: output as CFMutableData))
        var mediaBox = CGRect(x: 0, y: 0, width: 1_080, height: pageHeight)
        let context = try XCTUnwrap(CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ))

        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(mediaBox)
            let topColor: CGColor = pageIndex == 0
                ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
                : CGColor(red: 1, green: 1, blue: 0, alpha: 1)
            let bottomColor: CGColor = pageIndex == 0
                ? CGColor(red: 0, green: 1, blue: 0, alpha: 1)
                : CGColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.setFillColor(bottomColor)
            context.fill(CGRect(x: 0, y: 0, width: mediaBox.width, height: 32))
            context.setFillColor(topColor)
            context.fill(CGRect(
                x: 0,
                y: mediaBox.height - 32,
                width: mediaBox.width,
                height: 32
            ))
            // Cross the renderer's 2,048-row band boundary on each page so a
            // dropped/reversed seam becomes observable in the final PNG.
            context.setFillColor(CGColor(gray: 0, alpha: 1))
            context.fill(CGRect(
                x: 96,
                y: mediaBox.height - 2_064,
                width: 32,
                height: 32
            ))
            context.endPDFPage()
        }
        context.closePDF()
        return output as Data
    }

    private func XCTAssertColor(
        _ bitmap: NSBitmapImageRep,
        x: Int,
        y: Int,
        isNear expected: (red: CGFloat, green: CGFloat, blue: CGFloat),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
            XCTFail("Missing bitmap color", file: file, line: line)
            return
        }
        // Quartz tags the generated PDF and ImageIO color-manages it during
        // decode, so pure device primaries do not round-trip as exact 0/1.
        // This tolerance still unambiguously distinguishes all four markers.
        XCTAssertEqual(color.redComponent, expected.red, accuracy: 0.35, file: file, line: line)
        XCTAssertEqual(color.greenComponent, expected.green, accuracy: 0.35, file: file, line: line)
        XCTAssertEqual(color.blueComponent, expected.blue, accuracy: 0.35, file: file, line: line)
    }
}
