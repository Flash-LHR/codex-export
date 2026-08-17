import CryptoKit
import XCTest
@testable import CodexExportCore

final class SoftwareUpdateModelsTests: XCTestCase {
    func testStableSemanticVersionAcceptsThreeComponentsAndOptionalV() throws {
        let plain = try SemanticVersion("1.2.3")
        let tagged = try SemanticVersion("v0.3.40")

        XCTAssertEqual(plain, SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(tagged.description, "0.3.40")
        XCTAssertLessThan(tagged, plain)
    }

    func testStableSemanticVersionRejectsNonCanonicalAndPrereleaseValues() {
        for value in [
            "1.2",
            "1.2.3.4",
            "1.2.x",
            "1.02.3",
            "V1.2.3",
            "1.2.3+build.1"
        ] {
            assertThrows(
                .invalidSemanticVersion(value),
                try SemanticVersion(value)
            )
        }

        assertThrows(
            .prereleaseVersionNotAllowed("1.2.3-beta.1"),
            try SemanticVersion("1.2.3-beta.1")
        )
    }

    func testManifestIsDecodableSendableAndValidatesAllFields() throws {
        let data = validManifestData()
        let manifest = try JSONDecoder().decode(
            SoftwareUpdateManifest.self,
            from: data
        )
        requireSendable(manifest)

        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.bundleIdentifier, "com.codexexport.menubar")
        XCTAssertEqual(manifest.version, "v0.3.40")
        XCTAssertEqual(manifest.build, 41)
        XCTAssertEqual(manifest.assetName, "Codex Export 0.3.40.zip")
        XCTAssertEqual(manifest.size, 1_024)

        let validated = try SoftwareUpdateSecurity.validate(
            manifest,
            expectedBundleIdentifier: "com.codexexport.menubar"
        )
        requireSendable(validated)
        XCTAssertEqual(validated.semanticVersion.description, "0.3.40")
        XCTAssertEqual(validated.softwareVersion.buildNumber, 41)
        XCTAssertEqual(
            validated.normalizedSHA256,
            String(repeating: "ab", count: 32)
        )
    }

    func testManifestDecodeAndValidationFailuresAreTyped() throws {
        assertThrows(
            .malformedManifest,
            try SoftwareUpdateSecurity.decodeManifest(
                from: Data(#"{"schemaVersion":1}"#.utf8)
            )
        )

        let valid = try SoftwareUpdateSecurity.decodeManifest(
            from: validManifestData()
        )
        assertThrows(
            .unsupportedManifestSchema(expected: 2, actual: 1),
            try SoftwareUpdateSecurity.validate(
                valid,
                expectedBundleIdentifier: "com.codexexport.menubar",
                supportedSchemaVersion: 2
            )
        )
        assertThrows(
            .bundleIdentityMismatch(
                expected: "com.example.other",
                actual: "com.codexexport.menubar"
            ),
            try SoftwareUpdateSecurity.validate(
                valid,
                expectedBundleIdentifier: "com.example.other"
            )
        )

        let traversal = manifest(assetName: "../update.zip")
        assertThrows(
            .invalidAssetName("../update.zip"),
            try SoftwareUpdateSecurity.validate(
                traversal,
                expectedBundleIdentifier: "com.codexexport.menubar"
            )
        )

        let badDigest = manifest(sha256: "not-a-digest")
        assertThrows(
            .invalidSHA256("not-a-digest"),
            try SoftwareUpdateSecurity.validate(
                badDigest,
                expectedBundleIdentifier: "com.codexexport.menubar"
            )
        )
    }

    func testSHA256HexAndDigestVerification() throws {
        let data = Data("abc".utf8)
        let digest = "ba7816bf8f01cfea414140de5dae2223" +
            "b00361a396177a9cb410ff61f20015ad"

        XCTAssertEqual(SoftwareUpdateSecurity.sha256Hex(of: data), digest)
        XCTAssertNoThrow(
            try SoftwareUpdateSecurity.verifySHA256(
                digest.uppercased(),
                of: data
            )
        )
        assertThrows(
            .digestMismatch(
                expected: String(repeating: "0", count: 64),
                actual: digest
            ),
            try SoftwareUpdateSecurity.verifySHA256(
                String(repeating: "0", count: 64),
                of: data
            )
        )
    }

    func testDetachedEd25519SignatureVerification() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("signed manifest bytes".utf8)
        let signature = try privateKey.signature(for: payload)
        let publicKey = privateKey.publicKey.rawRepresentation

        XCTAssertNoThrow(
            try SoftwareUpdateSecurity.verifyDetachedSignature(
                signature,
                for: payload,
                publicKey: publicKey
            )
        )
        assertThrows(
            .invalidSignature,
            try SoftwareUpdateSecurity.verifyDetachedSignature(
                signature,
                for: Data("tampered".utf8),
                publicKey: publicKey
            )
        )
        assertThrows(
            .invalidPublicKey,
            try SoftwareUpdateSecurity.verifyDetachedSignature(
                signature,
                for: payload,
                publicKey: Data(repeating: 0, count: 31)
            )
        )
        assertThrows(
            .invalidSignatureEncoding,
            try SoftwareUpdateSecurity.verifyDetachedSignature(
                Data(repeating: 0, count: 63),
                for: payload,
                publicKey: publicKey
            )
        )
    }

    func testAuthenticateManifestVerifiesExactBytesBeforeDecoding() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let manifestData = validManifestData()
        let signature = try privateKey.signature(for: manifestData)

        let authenticated = try SoftwareUpdateSecurity.authenticateManifest(
            manifestData,
            detachedSignature: signature,
            publicKey: privateKey.publicKey.rawRepresentation,
            expectedBundleIdentifier: "com.codexexport.menubar"
        )
        XCTAssertEqual(authenticated.manifest.build, 41)

        var tampered = manifestData
        tampered.append(0x20)
        assertThrows(
            .invalidSignature,
            try SoftwareUpdateSecurity.authenticateManifest(
                tampered,
                detachedSignature: signature,
                publicKey: privateKey.publicKey.rawRepresentation,
                expectedBundleIdentifier: "com.codexexport.menubar"
            )
        )
    }

    func testUpgradeRequiresMonotonicBuildWithoutMarketingDowngrade() throws {
        let current = try SoftwareVersion(
            marketingVersion: "0.3.40",
            buildNumber: 41
        )
        let candidate = try SoftwareVersion(
            marketingVersion: "0.3.41",
            buildNumber: 42
        )
        XCTAssertNoThrow(
            try SoftwareUpdateSecurity.requireUpgrade(
                candidate: candidate,
                over: current
            )
        )

        let replay = try SoftwareVersion(
            marketingVersion: "0.3.41",
            buildNumber: 41
        )
        assertThrows(
            .downgradeOrReplay(current: current, candidate: replay),
            try SoftwareUpdateSecurity.requireUpgrade(
                candidate: replay,
                over: current
            )
        )
    }

    private func validManifestData() -> Data {
        Data(
            #"{"schemaVersion":1,"bundleIdentifier":"com.codexexport.menubar","version":"v0.3.40","build":41,"assetName":"Codex Export 0.3.40.zip","sha256":"abababababababababababababababababababababababababababababababab","size":1024}"#.utf8
        )
    }

    private func manifest(
        assetName: String = "Codex Export 0.3.40.zip",
        sha256: String = String(repeating: "ab", count: 32)
    ) -> SoftwareUpdateManifest {
        SoftwareUpdateManifest(
            schemaVersion: 1,
            bundleIdentifier: "com.codexexport.menubar",
            version: "0.3.40",
            build: 41,
            assetName: assetName,
            sha256: sha256,
            size: 1_024
        )
    }

    private func assertThrows<T>(
        _ expected: SoftwareUpdateError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(
                error as? SoftwareUpdateError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func requireSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
