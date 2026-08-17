import CryptoKit
import Foundation

/// A stable SemVer value accepted by the update channel.
///
/// Stable update versions contain exactly three decimal components. A leading
/// lowercase `v` is accepted for compatibility with conventional release tags.
public struct SemanticVersion: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let major: UInt64
    public let minor: UInt64
    public let patch: UInt64

    public init(major: UInt64, minor: UInt64, patch: UInt64) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init(_ rawValue: String) throws {
        let version = rawValue.hasPrefix("v")
            ? rawValue.dropFirst()
            : rawValue[...]

        if version.contains("-") {
            throw SoftwareUpdateError.prereleaseVersionNotAllowed(rawValue)
        }

        let components = version.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard components.count == 3,
              let major = Self.parseNumericComponent(components[0]),
              let minor = Self.parseNumericComponent(components[1]),
              let patch = Self.parseNumericComponent(components[2]) else {
            throw SoftwareUpdateError.invalidSemanticVersion(rawValue)
        }

        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String {
        "\(major).\(minor).\(patch)"
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func parseNumericComponent(_ component: Substring) -> UInt64? {
        guard !component.isEmpty,
              component.utf8.allSatisfy({ (48...57).contains($0) }),
              component.count == 1 || component.first != "0" else {
            return nil
        }
        return UInt64(component)
    }
}

/// The two-part identity used to reject downgrade and replay attempts.
public struct SoftwareVersion: Hashable, Comparable, Sendable {
    public let marketingVersion: SemanticVersion
    public let buildNumber: UInt64

    public init(marketingVersion: SemanticVersion, buildNumber: UInt64) {
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
    }

    public init(marketingVersion: String, buildNumber: UInt64) throws {
        self.init(
            marketingVersion: try SemanticVersion(marketingVersion),
            buildNumber: buildNumber
        )
    }

    /// Build numbers are the monotonic release ordering. Marketing version is
    /// only a deterministic tie-breaker for sorting already-validated values.
    public static func < (lhs: SoftwareVersion, rhs: SoftwareVersion) -> Bool {
        if lhs.buildNumber != rhs.buildNumber {
            return lhs.buildNumber < rhs.buildNumber
        }
        return lhs.marketingVersion < rhs.marketingVersion
    }
}

/// The complete payload covered by the detached update signature.
public struct SoftwareUpdateManifest: Decodable, Hashable, Sendable {
    public let schemaVersion: UInt64
    public let bundleIdentifier: String
    public let version: String
    public let build: UInt64
    public let assetName: String
    public let sha256: String
    public let size: UInt64

    public init(
        schemaVersion: UInt64,
        bundleIdentifier: String,
        version: String,
        build: UInt64,
        assetName: String,
        sha256: String,
        size: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.build = build
        self.assetName = assetName
        self.sha256 = sha256
        self.size = size
    }
}

/// A manifest whose security-sensitive fields have passed local validation.
public struct ValidatedSoftwareUpdateManifest: Hashable, Sendable {
    public let manifest: SoftwareUpdateManifest
    public let semanticVersion: SemanticVersion
    public let normalizedSHA256: String

    public var softwareVersion: SoftwareVersion {
        SoftwareVersion(
            marketingVersion: semanticVersion,
            buildNumber: manifest.build
        )
    }

    fileprivate init(
        manifest: SoftwareUpdateManifest,
        semanticVersion: SemanticVersion,
        normalizedSHA256: String
    ) {
        self.manifest = manifest
        self.semanticVersion = semanticVersion
        self.normalizedSHA256 = normalizedSHA256
    }
}

public enum SoftwareUpdateError: Error, Equatable, Sendable {
    case invalidSemanticVersion(String)
    case prereleaseVersionNotAllowed(String)
    case malformedManifest
    case unsupportedManifestSchema(expected: UInt64, actual: UInt64)
    case invalidBundleIdentifier(String)
    case bundleIdentityMismatch(expected: String, actual: String)
    case invalidBuildNumber(UInt64)
    case invalidAssetName(String)
    case invalidAssetSize(UInt64)
    case invalidSHA256(String)
    case invalidPublicKey
    case invalidSignatureEncoding
    case invalidSignature
    case digestMismatch(expected: String, actual: String)
    case downgradeOrReplay(current: SoftwareVersion, candidate: SoftwareVersion)
}

extension SoftwareUpdateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSemanticVersion(let version):
            return "Invalid stable semantic version: \(version)"
        case .prereleaseVersionNotAllowed(let version):
            return "Prerelease versions are not allowed on the stable channel: \(version)"
        case .malformedManifest:
            return "The update manifest is malformed."
        case .unsupportedManifestSchema(let expected, let actual):
            return "Unsupported manifest schema \(actual); expected \(expected)."
        case .invalidBundleIdentifier(let identifier):
            return "Invalid bundle identifier: \(identifier)"
        case .bundleIdentityMismatch(let expected, let actual):
            return "Bundle identifier \(actual) does not match \(expected)."
        case .invalidBuildNumber(let build):
            return "Invalid build number: \(build)"
        case .invalidAssetName(let name):
            return "Invalid update asset name: \(name)"
        case .invalidAssetSize(let size):
            return "Invalid update asset size: \(size)"
        case .invalidSHA256(let digest):
            return "Invalid SHA-256 digest: \(digest)"
        case .invalidPublicKey:
            return "The Ed25519 public key is invalid."
        case .invalidSignatureEncoding:
            return "The detached Ed25519 signature has an invalid encoding."
        case .invalidSignature:
            return "The detached Ed25519 signature is invalid."
        case .digestMismatch(let expected, let actual):
            return "SHA-256 mismatch; expected \(expected), got \(actual)."
        case .downgradeOrReplay:
            return "The candidate update is not newer than the installed build."
        }
    }
}

/// Security primitives for authenticating manifests and downloaded assets.
/// CryptoKit types do not escape this API.
public enum SoftwareUpdateSecurity {
    public static func decodeManifest(from data: Data) throws -> SoftwareUpdateManifest {
        do {
            return try JSONDecoder().decode(SoftwareUpdateManifest.self, from: data)
        } catch {
            throw SoftwareUpdateError.malformedManifest
        }
    }

    public static func validate(
        _ manifest: SoftwareUpdateManifest,
        expectedBundleIdentifier: String,
        supportedSchemaVersion: UInt64 = 1
    ) throws -> ValidatedSoftwareUpdateManifest {
        guard manifest.schemaVersion == supportedSchemaVersion else {
            throw SoftwareUpdateError.unsupportedManifestSchema(
                expected: supportedSchemaVersion,
                actual: manifest.schemaVersion
            )
        }
        guard Self.isValidBundleIdentifier(manifest.bundleIdentifier) else {
            throw SoftwareUpdateError.invalidBundleIdentifier(
                manifest.bundleIdentifier
            )
        }
        guard manifest.bundleIdentifier == expectedBundleIdentifier else {
            throw SoftwareUpdateError.bundleIdentityMismatch(
                expected: expectedBundleIdentifier,
                actual: manifest.bundleIdentifier
            )
        }

        let semanticVersion = try SemanticVersion(manifest.version)
        guard manifest.build > 0 else {
            throw SoftwareUpdateError.invalidBuildNumber(manifest.build)
        }
        guard Self.isSafeAssetName(manifest.assetName) else {
            throw SoftwareUpdateError.invalidAssetName(manifest.assetName)
        }
        guard manifest.size > 0 else {
            throw SoftwareUpdateError.invalidAssetSize(manifest.size)
        }
        let normalizedSHA256 = try Self.normalizeSHA256Hex(manifest.sha256)

        return ValidatedSoftwareUpdateManifest(
            manifest: manifest,
            semanticVersion: semanticVersion,
            normalizedSHA256: normalizedSHA256
        )
    }

    /// Verifies the signature over the exact manifest bytes before decoding.
    public static func authenticateManifest(
        _ manifestData: Data,
        detachedSignature: Data,
        publicKey: Data,
        expectedBundleIdentifier: String,
        supportedSchemaVersion: UInt64 = 1
    ) throws -> ValidatedSoftwareUpdateManifest {
        try verifyDetachedSignature(
            detachedSignature,
            for: manifestData,
            publicKey: publicKey
        )
        let manifest = try decodeManifest(from: manifestData)
        return try validate(
            manifest,
            expectedBundleIdentifier: expectedBundleIdentifier,
            supportedSchemaVersion: supportedSchemaVersion
        )
    }

    /// Verifies a raw 64-byte Ed25519 signature using a raw 32-byte public key.
    public static func verifyDetachedSignature(
        _ signature: Data,
        for payload: Data,
        publicKey: Data
    ) throws {
        guard publicKey.count == 32 else {
            throw SoftwareUpdateError.invalidPublicKey
        }
        guard signature.count == 64 else {
            throw SoftwareUpdateError.invalidSignatureEncoding
        }

        let signingKey: Curve25519.Signing.PublicKey
        do {
            signingKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: publicKey
            )
        } catch {
            throw SoftwareUpdateError.invalidPublicKey
        }

        guard signingKey.isValidSignature(signature, for: payload) else {
            throw SoftwareUpdateError.invalidSignature
        }
    }

    public static func sha256Hex(of data: Data) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(SHA256.byteCount * 2)
        for byte in SHA256.hash(data: data) {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0F)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    public static func verifySHA256(
        _ expectedHex: String,
        of data: Data
    ) throws {
        let expected = try normalizeSHA256Hex(expectedHex)
        let actual = sha256Hex(of: data)
        guard expected == actual else {
            throw SoftwareUpdateError.digestMismatch(
                expected: expected,
                actual: actual
            )
        }
    }

    public static func requireUpgrade(
        candidate: SoftwareVersion,
        over current: SoftwareVersion
    ) throws {
        guard candidate.buildNumber > current.buildNumber,
              candidate.marketingVersion >= current.marketingVersion else {
            throw SoftwareUpdateError.downgradeOrReplay(
                current: current,
                candidate: candidate
            )
        }
    }

    private static func normalizeSHA256Hex(_ value: String) throws -> String {
        guard value.utf8.count == SHA256.byteCount * 2 else {
            throw SoftwareUpdateError.invalidSHA256(value)
        }

        var normalized: [UInt8] = []
        normalized.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 48...57, 97...102:
                normalized.append(byte)
            case 65...70:
                normalized.append(byte + 32)
            default:
                throw SoftwareUpdateError.invalidSHA256(value)
            }
        }
        return String(decoding: normalized, as: UTF8.self)
    }

    private static func isValidBundleIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.first != ".",
              value.last != ".",
              value.contains(".") else {
            return false
        }
        return value.utf8.allSatisfy {
            (48...57).contains($0)
                || (65...90).contains($0)
                || (97...122).contains($0)
                || $0 == 45
                || $0 == 46
        }
    }

    private static func isSafeAssetName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.utf8.contains(0)
    }
}
