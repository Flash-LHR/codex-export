import Foundation
import WebKit
import XCTest
@testable import CodexExportCore

@MainActor
final class WebRendererResourceTests: XCTestCase {
    func testPackagedPageKeepsTheOfflineSecurityBoundary() throws {
        let directory = testRendererResourceDirectory()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("renderer.html").path
        ))
        let html = try String(
            contentsOf: directory.appendingPathComponent("renderer.html"),
            encoding: .utf8
        )
        let script = try String(
            contentsOf: directory.appendingPathComponent("renderer.js"),
            encoding: .utf8
        )
        let css = try String(
            contentsOf: directory.appendingPathComponent("renderer.css"),
            encoding: .utf8
        )

        for policy in [
            "default-src 'none'",
            "connect-src 'none'",
            "img-src 'none'",
            "script-src 'self'",
            "font-src 'self'"
        ] {
            XCTAssertTrue(html.contains(policy), "Missing CSP directive: \(policy)")
        }
        XCTAssertTrue(script.contains("html: false"))
        XCTAssertTrue(script.contains("linkify: false"))
        XCTAssertFalse(script.contains("serializeSVG"))
        XCTAssertFalse(script.contains("foreignObject"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(css.contains("http://"))
        XCTAssertFalse(css.contains("https://"))

        for blockedAPI in [
            "window.fetch",
            "window.XMLHttpRequest",
            "window.WebSocket",
            "window.EventSource",
            "navigator.sendBeacon"
        ] {
            XCTAssertTrue(
                WebMarkdownRenderer.networkBlockingScript.contains(blockedAPI),
                "Missing injected network block: \(blockedAPI)"
            )
        }
    }

    func testNavigationPolicyAllowsOnlyInternalFileLoads() {
        let fileURL = URL(fileURLWithPath: "/tmp/renderer.html")
        let remoteURL = URL(string: "https://example.invalid/renderer.html")

        XCTAssertTrue(WebMarkdownRenderer.allowsNavigation(type: .other, url: fileURL))
        XCTAssertFalse(WebMarkdownRenderer.allowsNavigation(type: .linkActivated, url: fileURL))
        XCTAssertFalse(WebMarkdownRenderer.allowsNavigation(type: .other, url: remoteURL))
        XCTAssertTrue(WebMarkdownRenderer.allowsNavigationResponse(url: fileURL))
        XCTAssertFalse(WebMarkdownRenderer.allowsNavigationResponse(url: remoteURL))
    }

    func testWarningStartsStrictlyAboveOneHundredThousandPixels() {
        XCTAssertNil(WebMarkdownRenderer.warning(forHeight: 100_000))
        XCTAssertNotNil(WebMarkdownRenderer.warning(forHeight: 100_001))
    }

    func testSingleImageHeightLimitIsFourHundredThousandPixels() {
        XCTAssertEqual(WebMarkdownRenderer.maximumHeight, 400_000)
    }

    func testTimeoutAndCancellationRetireTheMutableWebView() {
        XCTAssertTrue(WebMarkdownRenderer.requiresFreshWebView(
            after: WebMarkdownRendererError.timedOut
        ))
        XCTAssertTrue(WebMarkdownRenderer.requiresFreshWebView(
            after: CancellationError()
        ))
        XCTAssertFalse(WebMarkdownRenderer.requiresFreshWebView(
            after: WebMarkdownRendererError.scriptFailed
        ))
    }
}
