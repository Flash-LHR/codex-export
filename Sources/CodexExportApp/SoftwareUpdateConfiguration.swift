import Foundation

struct SoftwareUpdateConfiguration: Sendable {
    static let repositoryInfoKey = "CodexExportUpdateRepository"
    static let publicKeyInfoKey = "CodexExportUpdatePublicKey"
    static let manifestAssetName = "Codex-Export-update.json"
    static let signatureAssetName = "Codex-Export-update.sig"

    let repository: String
    let publicKey: Data
    let bundleIdentifier: String
    let targetBundleURL: URL

    var repositoryURL: URL {
        URL(string: "https://github.com/\(repository)")!
    }

    func latestReleaseAssetURL(named assetName: String) -> URL {
        repositoryURL
            .appendingPathComponent("releases", isDirectory: true)
            .appendingPathComponent("latest", isDirectory: true)
            .appendingPathComponent("download", isDirectory: true)
            .appendingPathComponent(assetName, isDirectory: false)
    }

    static func load(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SoftwareUpdateConfiguration? {
        #if DEBUG
        let environmentRepository = environment["CODEX_EXPORT_UPDATE_REPOSITORY"]
        let environmentPublicKey = environment["CODEX_EXPORT_UPDATE_PUBLIC_KEY"]
        #else
        // Release builds trust only the values sealed into the signed bundle.
        // A launch environment must never be able to replace the update feed
        // or its Ed25519 trust root.
        let environmentRepository: String? = nil
        let environmentPublicKey: String? = nil
        #endif
        let repository = firstNonempty(
            environmentRepository,
            bundle.object(forInfoDictionaryKey: repositoryInfoKey) as? String
        )
        let encodedKey = firstNonempty(
            environmentPublicKey,
            bundle.object(forInfoDictionaryKey: publicKeyInfoKey) as? String
        )
        guard let repository,
              isValidRepository(repository),
              let encodedKey,
              let publicKey = Data(base64Encoded: encodedKey),
              publicKey.count == 32,
              let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier == "com.codexexport.menubar"
        else {
            return nil
        }

        let targetBundleURL = bundle.bundleURL.standardizedFileURL
        guard targetBundleURL.pathExtension == "app" else { return nil }

        return SoftwareUpdateConfiguration(
            repository: repository,
            publicKey: publicKey,
            bundleIdentifier: bundleIdentifier,
            targetBundleURL: targetBundleURL
        )
    }

    private static func firstNonempty(_ values: String?...) -> String? {
        values.lazy
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty && !$0.contains("$(") })
    }

    private static func isValidRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
        )
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.unicodeScalars.allSatisfy(allowed.contains)
                && part != "."
                && part != ".."
        }
    }
}
