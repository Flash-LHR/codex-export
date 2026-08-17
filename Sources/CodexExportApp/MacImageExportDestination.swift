import AppKit
import CodexExportCore
import CodexExportFeature
import Foundation

@MainActor
final class MacImageExportDestination: ImageExportDestination {
    func copy(_ result: RenderResult) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(result.pngData, forType: .png) else {
            throw DestinationError.clipboardUnavailable
        }
    }

    func save(_ result: RenderResult) async throws -> URL {
        let imageData = result.pngData
        return try await Task.detached(priority: .utility) {
            try Self.writePNG(imageData)
        }.value
    }

    nonisolated private static func writePNG(_ data: Data) throws -> URL {
        guard let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first else {
            throw DestinationError.downloadsUnavailable
        }
        let directory = downloads.appendingPathComponent(
            "Codex Exports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stem = "Codex Export \(formatter.string(from: Date()))"
        for suffix in 0..<10_000 {
            let numbered = suffix == 0 ? stem : "\(stem) \(suffix + 1)"
            let candidate = directory
                .appendingPathComponent(numbered)
                .appendingPathExtension("png")
            do {
                try data.write(
                    to: candidate,
                    options: [.atomic, .withoutOverwriting]
                )
                return candidate
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw DestinationError.cannotCreateFile
    }

    private enum DestinationError: LocalizedError {
        case clipboardUnavailable
        case downloadsUnavailable
        case cannotCreateFile

        var errorDescription: String? {
            switch self {
            case .clipboardUnavailable:
                return "无法写入剪贴板，请重试。"
            case .downloadsUnavailable:
                return "无法找到下载文件夹。"
            case .cannotCreateFile:
                return "无法创建导出文件。"
            }
        }
    }
}
