import AppKit
import CodexExportCore
import Foundation
import ImageIO

/// Runs the real packaged WebKit renderer inside an AppKit run loop. This is a
/// release diagnostic rather than a user-facing mode; it validates the app's
/// bundled resources in the same process shape used in production.
@MainActor
enum RendererSmoke {
    static let argument = "--renderer-smoke"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    static func start() {
        NSApp.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var exitCode: Int32 = 1
            do {
                let renderer = WebMarkdownRenderer(
                    resourceDirectory: AppResources.webRendererDirectory
                )
                async let short = renderer.render(messages: [
                    RenderMessage(
                        role: .user,
                        text: "## Smoke\n\n| A | B |\n| - | - |\n| 公式 | $E=mc^2$ |"
                    )
                ])
                async let tall = renderer.render(messages: [
                    RenderMessage(
                        role: .assistant,
                        text: Array(
                            repeating: "**并发渲染标记**与公式 $a^2+b^2=c^2$。",
                            count: 120
                        ).joined(separator: "\n\n")
                            + "\n\n<script>window.owned = true</script>"
                            + "\n<img src='https://example.invalid/leak'>"
                    )
                ])
                let (shortResult, tallResult) = try await (short, tall)
                guard isValidPNG(shortResult),
                      isValidPNG(tallResult),
                      tallResult.height > shortResult.height * 3 else {
                    throw SmokeError.invalidResult
                }
                exitCode = 0
            } catch {
                fputs("renderer smoke failed: \(error.localizedDescription)\n", stderr)
            }
            fflush(stderr)
            Darwin.exit(exitCode)
        }
    }

    private static func isValidPNG(_ result: RenderResult) -> Bool {
        guard result.width == WebMarkdownRenderer.outputWidth,
              result.height > 0,
              let source = CGImageSourceCreateWithData(
                result.pngData as CFData,
                nil
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                nil
              ) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == result.width,
              properties[kCGImagePropertyPixelHeight] as? Int == result.height else {
            return false
        }
        return true
    }

    private enum SmokeError: LocalizedError {
        case invalidResult

        var errorDescription: String? {
            "渲染结果未通过 PNG 尺寸或并发隔离检查。"
        }
    }
}
