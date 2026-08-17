import AppKit
import Foundation
import WebKit

public enum WebMarkdownRendererError: Error, Equatable, LocalizedError {
    case noMessages
    case resourcesMissing
    case pageLoadFailed
    case scriptFailed
    case invalidPageHeight
    case exceedsMaximumHeight(measured: Int, maximum: Int)
    case snapshotFailed
    case invalidSnapshot
    case timedOut
    case encodedImageTooLarge(maximumBytes: Int)
    case bitmapAllocationFailed
    case pngEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .noMessages:
            return "没有可导出的消息。"
        case .resourcesMissing:
            return "Markdown 渲染资源不完整，请重新安装应用。"
        case .pageLoadFailed:
            return "无法载入 Markdown 渲染器。"
        case .scriptFailed:
            return "Markdown 或公式排版失败。"
        case .invalidPageHeight:
            return "无法确定导出图片高度。"
        case .exceedsMaximumHeight(let measured, let maximum):
            return "图片高度为 \(measured)px，超过当前单张图片 \(maximum)px 上限。请减少选择的消息。"
        case .snapshotFailed:
            return "无法生成 Markdown 的矢量排版结果。"
        case .invalidSnapshot:
            return "Markdown 排版结果不是有效图片。"
        case .timedOut:
            return "Markdown 排版超时，请减少选择的内容后重试。"
        case .encodedImageTooLarge(let maximumBytes):
            return "PNG 数据超过 \(maximumBytes / 1_048_576) MiB 安全上限。请减少选择的消息。"
        case .bitmapAllocationFailed:
            return "无法分配图片内存。请减少选择的消息。"
        case .pngEncodingFailed:
            return "无法生成 PNG 图片。"
        }
    }
}

/// Offline Markdown and KaTeX renderer backed by one reusable, invisible
/// WKWebView. All untrusted content is passed as script arguments rather than
/// interpolated into HTML; the bundled page disables user HTML and networking.
@MainActor
public final class WebMarkdownRenderer: NSObject {
    public static let outputWidth = 1_080
    static let warningHeight = 100_000
    static let maximumHeight = 400_000
    static let maximumEncodedPNGBytes = 64 * 1_024 * 1_024
    private static let viewportHeight = 2_048
    private static let maximumInputUTF16Count = 2_000_000
    private static let pdfRasterBandHeight = 2_048
    private static let pdfRasterBleed = 2
    static let networkBlockingScript = """
    (() => {
      const blocked = () => Promise.reject(new Error('Network disabled'));
      window.fetch = blocked;
      window.XMLHttpRequest = function () { throw new Error('Network disabled'); };
      window.WebSocket = function () { throw new Error('Network disabled'); };
      window.EventSource = function () { throw new Error('Network disabled'); };
      navigator.sendBeacon = () => false;
    })();
    """

    private var webView: WKWebView
    private let hostWindow: NSWindow
    private let resourceDirectory: URL?
    private let renderFIFO = RenderFIFO()
    private let operationCoordinator = WebOperationCoordinator()
    private var pageIsLoaded = false
    private var activeNavigation: WKNavigation?
    private var navigationCompletion: (@Sendable (Result<Void, Error>) -> Void)?

    public init(resourceDirectory: URL?) {
        _ = NSApplication.shared
        self.resourceDirectory = resourceDirectory
        webView = Self.makeWebView()
        hostWindow = NSWindow(
            contentRect: webView.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        super.init()
        installWebView(webView)
    }

    private static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.networkBlockingScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        configuration.userContentController = controller

        return WKWebView(
            frame: NSRect(
                x: 0,
                y: 0,
                width: Self.outputWidth,
                height: Self.viewportHeight
            ),
            configuration: configuration
        )
    }

    private func installWebView(_ webView: WKWebView) {
        hostWindow.collectionBehavior = [.stationary, .ignoresCycle]
        hostWindow.ignoresMouseEvents = true
        hostWindow.alphaValue = 0.001
        webView.navigationDelegate = self
        webView.uiDelegate = self
        hostWindow.contentView = webView
    }

    public func render(
        messages: [RenderMessage],
        progress: ((Double) -> Void)? = nil
    ) async throws -> RenderResult {
        try await renderFIFO.withPermit {
            try await renderWithPermit(messages: messages, progress: progress)
        }
    }

    private func renderWithPermit(
        messages: [RenderMessage],
        progress: ((Double) -> Void)?
    ) async throws -> RenderResult {
        do {
            try Task.checkCancellation()
            try await ensurePageIsLoaded()
            hostWindow.orderFront(nil)
            defer { hostWindow.orderOut(nil) }

            let height = try await prepareTranscript(messages: messages)
            guard height <= Self.maximumHeight else {
                throw WebMarkdownRendererError.exceedsMaximumHeight(
                    measured: height,
                    maximum: Self.maximumHeight
                )
            }

            try await resetViewport()

            progress?(0)
            let pngData = try await renderPDFPNG(height: height, progress: progress)
            return RenderResult(
                pngData: pngData,
                width: Self.outputWidth,
                height: height,
                warning: Self.warning(forHeight: height)
            )
        } catch {
            // A timeout does not prove that WebKit has stopped mutating its
            // page. Active cancellation can also settle only when that timeout
            // fires. Retire the mutable DOM while this render still owns the
            // FIFO permit, so stale work can never overlap the next render.
            if Self.requiresFreshWebView(after: error) {
                replaceWebView()
            }
            throw error
        }
    }

    static func requiresFreshWebView(after error: Error) -> Bool {
        error is CancellationError
            || (error as? WebMarkdownRendererError) == .timedOut
    }

    private func replaceWebView() {
        let retiredWebView = webView
        retiredWebView.navigationDelegate = nil
        retiredWebView.uiDelegate = nil
        retiredWebView.stopLoading()

        pageIsLoaded = false
        activeNavigation = nil
        navigationCompletion = nil

        let replacement = Self.makeWebView()
        webView = replacement
        installWebView(replacement)
    }

    static func warning(forHeight height: Int) -> String? {
        guard height > warningHeight else { return nil }
        return "图片高度为 \(height)px，复制或打开可能需要较多内存。"
    }

    private func renderPDFPNG(
        height: Int,
        progress: ((Double) -> Void)?
    ) async throws -> Data {
        try Task.checkCancellation()
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(
            x: 0,
            y: 0,
            width: Self.outputWidth,
            height: height
        )

        let pdfData: Data
        do {
            pdfData = try await operationCoordinator.perform(
                timeoutError: WebMarkdownRendererError.timedOut
            ) { completion in
                webView.createPDF(configuration: configuration, completionHandler: completion)
            }
        } catch {
            if error is CancellationError { throw error }
            if let rendererError = error as? WebMarkdownRendererError {
                throw rendererError
            }
            throw WebMarkdownRendererError.snapshotFailed
        }

        try Task.checkCancellation()
        progress?(0.02)
        return try await Self.rasterizePDF(
            pdfData,
            expectedHeight: height
        ) { fraction in
            progress?(0.02 + (fraction * 0.98))
        }
    }

    /// Converts WebKit's paged PDF into one top-to-bottom PNG without ever
    /// allocating the full-height bitmap. Internal so page stitching,
    /// orientation, and exact-height behavior can be covered independently of
    /// WKWebView navigation in unit tests.
    static func rasterizePDF(
        _ pdfData: Data,
        expectedHeight: Int,
        progress: ((Double) -> Void)? = nil
    ) async throws -> Data {
        guard expectedHeight > 0,
              expectedHeight <= Self.maximumHeight,
              let provider = CGDataProvider(data: pdfData as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else {
            throw WebMarkdownRendererError.invalidSnapshot
        }

        var pages: [(page: CGPDFPage, box: CGRect, height: Int)] = []
        pages.reserveCapacity(document.numberOfPages)
        var stitchedHeight = 0
        for pageIndex in 1...document.numberOfPages {
            guard let page = document.page(at: pageIndex) else {
                throw WebMarkdownRendererError.invalidSnapshot
            }
            let box = page.getBoxRect(.mediaBox)
            guard box.minX.isFinite,
                  box.minY.isFinite,
                  box.width.isFinite,
                  box.height.isFinite,
                  box.width > 0,
                  box.height > 0,
                  box.width <= CGFloat(Int.max),
                  box.height <= CGFloat(Int.max) else {
                throw WebMarkdownRendererError.invalidSnapshot
            }
            let roundedWidth = Int(box.width.rounded())
            let roundedHeight = Int(box.height.rounded())
            guard page.rotationAngle == 0,
                  roundedWidth == Self.outputWidth,
                  abs(box.width - CGFloat(roundedWidth)) < 0.01,
                  roundedHeight > 0,
                  abs(box.height - CGFloat(roundedHeight)) < 0.01,
                  stitchedHeight <= expectedHeight - roundedHeight else {
                throw WebMarkdownRendererError.invalidSnapshot
            }
            stitchedHeight += roundedHeight
            pages.append((page, box, roundedHeight))
        }
        guard stitchedHeight == expectedHeight else {
            throw WebMarkdownRendererError.invalidSnapshot
        }

        let writer = try PNGStreamWriter(
            width: Self.outputWidth,
            height: expectedHeight,
            maximumBytes: Self.maximumEncodedPNGBytes
        )
        let rowByteCount = Self.outputWidth * 4
        var previousRow = [UInt8](repeating: 0, count: rowByteCount)
        var filteredRow = [UInt8](repeating: 0, count: rowByteCount + 1)
        var writtenRows = 0

        for descriptor in pages {
            var pageTop = 0
            while pageTop < descriptor.height {
                try Task.checkCancellation()
                let bandHeight = min(
                    Self.pdfRasterBandHeight,
                    descriptor.height - pageTop
                )
                try autoreleasepool {
                    try Self.writePDFBand(
                        page: descriptor.page,
                        box: descriptor.box,
                        pageHeight: descriptor.height,
                        bandTop: pageTop,
                        bandHeight: bandHeight,
                        writer: writer,
                        previousRow: &previousRow,
                        filteredRow: &filteredRow
                    )
                }
                pageTop += bandHeight
                writtenRows += bandHeight
                progress?(Double(writtenRows) / Double(expectedHeight))
                await Task.yield()
            }
        }

        guard writtenRows == expectedHeight else {
            throw WebMarkdownRendererError.invalidSnapshot
        }
        return try writer.finish()
    }

    private static func writePDFBand(
        page: CGPDFPage,
        box: CGRect,
        pageHeight: Int,
        bandTop: Int,
        bandHeight: Int,
        writer: PNGStreamWriter,
        previousRow: inout [UInt8],
        filteredRow: inout [UInt8]
    ) throws {
        let bleedTop = min(Self.pdfRasterBleed, bandTop)
        let bleedBottom = min(
            Self.pdfRasterBleed,
            pageHeight - (bandTop + bandHeight)
        )
        let renderTop = bandTop - bleedTop
        let renderHeight = bleedTop + bandHeight + bleedBottom
        let rowByteCount = Self.outputWidth * 4
        var pixels = Data(count: rowByteCount * renderHeight)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue

        try pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: Self.outputWidth,
                    height: renderHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: rowByteCount,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                  ) else {
                throw WebMarkdownRendererError.bitmapAllocationFailed
            }

            // Match the renderer's opaque canvas even if a future PDF producer
            // leaves an otherwise blank page area transparent.
            context.setFillColor(CGColor(
                red: 246.0 / 255.0,
                green: 245.0 / 255.0,
                blue: 242.0 / 255.0,
                alpha: 1
            ))
            context.fill(CGRect(
                x: 0,
                y: 0,
                width: Self.outputWidth,
                height: renderHeight
            ))
            context.setShouldAntialias(true)
            context.setAllowsAntialiasing(true)

            // PDF coordinates start at the bottom-left. Quartz's bitmap rows
            // are exposed here in visual top-to-bottom order, so translating
            // the requested top-origin slice is sufficient—no row reversal.
            let lowerPDFY = box.minY + box.height
                - CGFloat(renderTop + renderHeight)
            context.saveGState()
            context.translateBy(x: -box.minX, y: -lowerPDFY)
            context.drawPDFPage(page)
            context.restoreGState()
            context.flush()

            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for outputRow in 0..<bandHeight {
                let sourceOffset = (bleedTop + outputRow) * rowByteCount
                filteredRow[0] = 2
                for byteIndex in 0..<rowByteCount {
                    let current = bytes[sourceOffset + byteIndex]
                    filteredRow[byteIndex + 1] = current &- previousRow[byteIndex]
                    previousRow[byteIndex] = current
                }
                try writer.writeScanline(filteredRow)
            }
        }
    }

    private func prepareTranscript(messages: [RenderMessage]) async throws -> Int {
        guard !messages.isEmpty else { throw WebMarkdownRendererError.noMessages }
        let inputCount = messages.reduce(0) { partial, message in
            partial + message.text.utf16.count
        }
        guard inputCount <= Self.maximumInputUTF16Count else {
            throw WebMarkdownRendererError.scriptFailed
        }

        let payload: [[String: String]] = messages.map {
            ["role": $0.role.rawValue, "text": $0.text]
        }
        let height: Int
        do {
            height = try await operationCoordinator.perform(
                timeoutError: WebMarkdownRendererError.timedOut
            ) { completion in
                webView.callAsyncJavaScript(
                    "return await window.codexRenderer.renderTranscript(messages);",
                    arguments: ["messages": payload],
                    in: nil,
                    in: .page,
                    completionHandler: { result in
                        completion(result.flatMap { value in
                            guard let number = value as? NSNumber else {
                                return .failure(WebMarkdownRendererError.invalidPageHeight)
                            }
                            return .success(number.intValue)
                        })
                    }
                )
            }
        } catch {
            if error is CancellationError { throw error }
            if let rendererError = error as? WebMarkdownRendererError {
                throw rendererError
            }
            throw WebMarkdownRendererError.scriptFailed
        }

        guard height > 0 else { throw WebMarkdownRendererError.invalidPageHeight }
        return height
    }

    private func resetViewport() async throws {
        do {
            _ = try await operationCoordinator.perform(
                timeoutError: WebMarkdownRendererError.timedOut
            ) { completion in
                webView.callAsyncJavaScript(
                    "window.codexRenderer.resetViewport(); return true;",
                    arguments: [:],
                    in: nil,
                    in: .page,
                    completionHandler: { result in
                        completion(result.map { _ in true })
                    }
                )
            }
        } catch {
            if error is CancellationError { throw error }
            if let rendererError = error as? WebMarkdownRendererError {
                throw rendererError
            }
            throw WebMarkdownRendererError.scriptFailed
        }
    }

    private func ensurePageIsLoaded() async throws {
        guard !pageIsLoaded else { return }
        guard let resourceURL = resourceDirectory else {
            throw WebMarkdownRendererError.resourcesMissing
        }

        defer {
            navigationCompletion = nil
            activeNavigation = nil
        }
        do {
            let _: Void = try await operationCoordinator.perform(
                timeoutError: WebMarkdownRendererError.timedOut
            ) { [weak self] completion in
                guard let self else {
                    completion(.failure(WebMarkdownRendererError.pageLoadFailed))
                    return
                }
                navigationCompletion = completion
                activeNavigation = webView.loadFileURL(
                    resourceURL.appendingPathComponent("renderer.html"),
                    allowingReadAccessTo: resourceURL
                )
            }
        } catch {
            webView.stopLoading()
            throw error
        }
    }

    static func allowsNavigation(
        type: WKNavigationType,
        url: URL?
    ) -> Bool {
        type == .other && url?.isFileURL == true
    }

    static func allowsNavigationResponse(url: URL?) -> Bool {
        url?.isFileURL == true
    }

}

extension WebMarkdownRenderer: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === activeNavigation else { return }
        pageIsLoaded = true
        navigationCompletion?(.success(()))
    }

    public func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        guard navigation === activeNavigation else { return }
        navigationCompletion?(.failure(WebMarkdownRendererError.pageLoadFailed))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard navigation === activeNavigation else { return }
        navigationCompletion?(.failure(WebMarkdownRendererError.pageLoadFailed))
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard Self.allowsNavigation(
            type: navigationAction.navigationType,
            url: navigationAction.request.url
        ) else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(
            Self.allowsNavigationResponse(url: navigationResponse.response.url)
                ? .allow
                : .cancel
        )
    }
}

extension WebMarkdownRenderer: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
