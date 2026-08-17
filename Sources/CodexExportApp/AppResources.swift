import Foundation

enum AppResources {
    static var webRendererDirectory: URL? {
        candidates.first(where: isCompleteRendererDirectory)
    }

    private static var candidates: [URL] {
        var urls: [URL] = []
        if let bundled = Bundle.main.resourceURL {
            urls.append(bundled.appendingPathComponent("WebRenderer"))
        }
        if let override = ProcessInfo.processInfo.environment[
            "CODEX_EXPORT_RENDERER_RESOURCES"
        ], !override.isEmpty {
            urls.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        urls.append(
            URL(
                fileURLWithPath: FileManager.default.currentDirectoryPath,
                isDirectory: true
            )
            .appendingPathComponent("Resources/WebRenderer", isDirectory: true)
        )
        return urls
    }

    private static func isCompleteRendererDirectory(_ directory: URL) -> Bool {
        ["renderer.html", "renderer.css", "renderer.js"].allSatisfy {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0).path
            )
        }
    }
}
