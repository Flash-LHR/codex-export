import Foundation

/// Unit-test source checkouts load the renderer explicitly. Production only
/// resolves Bundle.main, so no developer `.build` fallback path is compiled
/// into the shipped executable.
func testRendererResourceDirectory(
    filePath: StaticString = #filePath
) -> URL {
    URL(fileURLWithPath: String(describing: filePath))
        .deletingLastPathComponent() // CodexExportCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // repository root
        .appendingPathComponent("Resources/WebRenderer", isDirectory: true)
}
