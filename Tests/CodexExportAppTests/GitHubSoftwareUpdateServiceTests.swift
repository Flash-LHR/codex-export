import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import CodexExportApp
@testable import CodexExportFeature

final class GitHubSoftwareUpdateServiceTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.removeHandler()
        super.tearDown()
    }

    func testAuthenticatesStableLatestReleaseAndReturnsCandidate() async throws {
        let fixture = try UpdateFixture()
        MockURLProtocol.install { request in
            try fixture.response(for: request)
        }
        let service = fixture.makeService()

        let candidate = try await service.latestUpdate(
            currentVersion: "0.3.40",
            currentBuild: 41
        )

        XCTAssertEqual(candidate?.version, "0.3.41")
        XCTAssertEqual(candidate?.build, 42)
        XCTAssertEqual(candidate?.assetName, fixture.assetName)
        XCTAssertEqual(candidate?.sha256, fixture.assetSHA256)
        XCTAssertEqual(candidate?.size, UInt64(fixture.archiveData.count))
    }

    func testIgnoresPrereleaseEvenWhenManifestIsPresent() async throws {
        let fixture = try UpdateFixture(prerelease: true)
        MockURLProtocol.install { request in
            try fixture.response(for: request)
        }

        let candidate = try await fixture.makeService().latestUpdate(
            currentVersion: "0.3.40",
            currentBuild: 41
        )

        XCTAssertNil(candidate)
    }

    func testRejectsTamperedManifestSignature() async throws {
        let fixture = try UpdateFixture(tamperSignature: true)
        MockURLProtocol.install { request in
            try fixture.response(for: request)
        }

        do {
            _ = try await fixture.makeService().latestUpdate(
                currentVersion: "0.3.40",
                currentBuild: 41
            )
            XCTFail("Expected signature verification to fail")
        } catch {
            XCTAssertNotNil(error as? LocalizedError)
        }
    }

    func testReturnsNilForInstalledOrOlderBuild() async throws {
        let fixture = try UpdateFixture()
        MockURLProtocol.install { request in
            try fixture.response(for: request)
        }

        let candidate = try await fixture.makeService().latestUpdate(
            currentVersion: "0.3.41",
            currentBuild: 42
        )

        XCTAssertNil(candidate)
    }

    func testPrepareDownloadsExtractsAndValidatesSignedApplication() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodexExportPrepareTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = try makeSignedApplicationArchive(in: root)
        let archiveData = try Data(contentsOf: archiveURL)
        let digest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        MockURLProtocol.install { request in
            let url = try XCTUnwrap(request.url)
            return (
                HTTPURLResponse(
                    url: url,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil
                )!,
                archiveData
            )
        }
        let fixture = try UpdateFixture()
        let candidate = SoftwareUpdateCandidate(
            version: "0.3.41",
            build: 42,
            assetName: archiveURL.lastPathComponent,
            assetURL: URL(string: "https://github.com/example/codex-export/releases/download/v0.3.41/\(archiveURL.lastPathComponent)")!,
            sha256: digest,
            size: UInt64(archiveData.count)
        )

        let prepared = try await fixture.makeService().prepare(candidate)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: prepared.appBundleURL.path)
        )
        XCTAssertEqual(prepared.version, "0.3.41")
        await fixture.makeService().discard(prepared)
    }

    func testInstallerAcknowledgesReadinessBeforeChangingTheCurrentApp() throws {
        let fixture = try InstallerFixture(newExecutable: "/usr/bin/true")
        defer { fixture.cleanup() }
        let process = try fixture.launchHelper(parentPID: getpid())

        try waitUntil {
            FileManager.default.fileExists(atPath: fixture.readyMarker.path)
        }
        XCTAssertEqual(try fixture.installedVersion(), "0.3.40")

        try Data(fixture.token.uuidString.utf8).write(
            to: fixture.cancelMarker,
            options: .atomic
        )
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try fixture.installedVersion(), "0.3.40")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.incoming.path)
        )
    }

    func testInstallerAtomicallySwapsAfterNewAppReportsHealthy() throws {
        let root = try makeInstallerTestRoot()
        let healthExecutable = try makeHealthReporterExecutable(in: root)
        let fixture = try InstallerFixture(
            root: root,
            newExecutable: healthExecutable.path
        )
        defer { fixture.cleanup() }

        let process = try fixture.launchHelper(parentPID: 999_999)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try fixture.installedVersion(), "0.3.41")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.incoming.path)
        )
    }

    func testInstallerRollsBackWhenNewAppDoesNotBecomeHealthy() throws {
        let fixture = try InstallerFixture(newExecutable: "/usr/bin/false")
        defer { fixture.cleanup() }

        let process = try fixture.launchHelper(parentPID: 999_999)
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try fixture.installedVersion(), "0.3.40")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.incoming.path)
        )
    }

    func testInstallerRefusesToReplaceANewerInstalledBuild() throws {
        let fixture = try InstallerFixture(newExecutable: "/usr/bin/true")
        defer { fixture.cleanup() }
        try fixture.replaceInstalledApplication(version: "0.3.42", build: 43)

        let process = try fixture.launchHelper(parentPID: 999_999)
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertEqual(try fixture.installedVersion(), "0.3.42")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.incoming.path)
        )
    }

    func testInstallerReadyAcknowledgementWinsOverLateCancellation() {
        let gate = InstallerLaunchReadinessGate()

        XCTAssertTrue(gate.acceptReady())
        XCTAssertFalse(gate.requestCancellation())
        XCTAssertTrue(gate.acceptReady())
    }

    func testInstallerCancellationWinsOverLateReadyAcknowledgement() {
        let gate = InstallerLaunchReadinessGate()

        XCTAssertTrue(gate.requestCancellation())
        XCTAssertFalse(gate.acceptReady())
        XCTAssertFalse(gate.requestCancellation())
    }

    private func makeSignedApplicationArchive(in root: URL) throws -> URL {
        let app = root.appendingPathComponent("Codex Export.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let executable = macOS.appendingPathComponent("CodexExportApp")
        let testExecutable = try XCTUnwrap(
            Bundle(for: Self.self).executableURL
        )
        try FileManager.default.copyItem(at: testExecutable, to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.codexexport.menubar",
            "CFBundleShortVersionString": "0.3.41",
            "CFBundleVersion": "42",
            "CFBundleExecutable": "CodexExportApp",
            "CFBundlePackageType": "APPL",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])

        let archive = root.appendingPathComponent("Codex-Export-macOS.zip")
        try run(
            "/usr/bin/ditto",
            ["-c", "-k", "--keepParent", app.path, archive.path]
        )
        return archive
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeInstallerTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
            .appendingPathComponent(
                "InstallerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func makeHealthReporterExecutable(in root: URL) throws -> URL {
        let source = root.appendingPathComponent("HealthReporter.swift")
        let executable = root.appendingPathComponent("HealthReporter")
        let program = #"""
        import Foundation

        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--software-update-health-token"),
           arguments.indices.contains(index + 1),
           let token = UUID(uuidString: arguments[index + 1]) {
            let marker = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexExportUpdates", isDirectory: true)
                .appendingPathComponent("Health", isDirectory: true)
                .appendingPathComponent(token.uuidString)
            try? FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data(token.uuidString.utf8).write(to: marker, options: .atomic)
            Thread.sleep(forTimeInterval: 4)
        }
        """#
        try Data(program.utf8).write(to: source, options: .atomic)
        try run(
            "/usr/bin/xcrun",
            [
                "swiftc",
                "-target", "arm64-apple-macos13.0",
                source.path,
                "-o", executable.path,
            ]
        )
        return executable
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw CocoaError(.coderReadCorrupt)
    }
}

private final class InstallerFixture {
    let root: URL
    let token = UUID()
    let bundleIdentifier: String
    let target: URL
    let sourceApplication: URL
    let workingDirectory: URL
    let readyMarker: URL
    let cancelMarker: URL
    let incoming: URL

    init(
        root: URL? = nil,
        newExecutable: String
    ) throws {
        let fileManager = FileManager.default
        let root = try root ?? Self.makeRoot()
        self.root = root
        bundleIdentifier = "com.codexexport.installer-test.\(UUID().uuidString)"
        let installDirectory = root.appendingPathComponent(
            "Install",
            isDirectory: true
        )
        workingDirectory = root.appendingPathComponent(
            "Working",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: installDirectory,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        target = installDirectory.appendingPathComponent(
            "Codex Export.app",
            isDirectory: true
        )
        sourceApplication = workingDirectory.appendingPathComponent(
            "New Codex Export.app",
            isDirectory: true
        )
        try Self.makeApplication(
            at: target,
            executable: "/usr/bin/true",
            bundleIdentifier: bundleIdentifier,
            version: "0.3.40",
            build: 41
        )
        try Self.makeApplication(
            at: sourceApplication,
            executable: newExecutable,
            bundleIdentifier: bundleIdentifier,
            version: "0.3.41",
            build: 42
        )
        readyMarker = workingDirectory.appendingPathComponent(
            ".installer-ready.\(token.uuidString)"
        )
        cancelMarker = workingDirectory.appendingPathComponent(
            ".installer-cancel.\(token.uuidString)"
        )
        incoming = installDirectory.appendingPathComponent(
            ".Codex Export.app.incoming.\(token.uuidString)",
            isDirectory: true
        )
    }

    func launchHelper(parentPID: pid_t) throws -> Process {
        let helper = try Self.helperExecutable()
        let process = Process()
        process.executableURL = helper
        process.arguments = [
            SoftwareUpdateInstaller.helperArgument,
            target.path,
            sourceApplication.path,
            workingDirectory.path,
            String(parentPID),
            bundleIdentifier,
            "0.3.41",
            "42",
            token.uuidString,
            readyMarker.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    func installedVersion() throws -> String {
        let info = try Data(
            contentsOf: target.appendingPathComponent("Contents/Info.plist")
        )
        let plist = try PropertyListSerialization.propertyList(
            from: info,
            format: nil
        ) as! [String: Any]
        return plist["CFBundleShortVersionString"] as! String
    }

    func replaceInstalledApplication(version: String, build: Int) throws {
        try FileManager.default.removeItem(at: target)
        try Self.makeApplication(
            at: target,
            executable: "/usr/bin/true",
            bundleIdentifier: bundleIdentifier,
            version: version,
            build: build
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(
            forName: bundleIdentifier
        )
    }

    private static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexExportUpdates", isDirectory: true)
            .appendingPathComponent(
                "InstallerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private static func makeApplication(
        at app: URL,
        executable: String,
        bundleIdentifier: String,
        version: String,
        build: Int
    ) throws {
        let fileManager = FileManager.default
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        let installedExecutable = macOS.appendingPathComponent("InstallerTestApp")
        try fileManager.copyItem(
            at: URL(fileURLWithPath: executable),
            to: installedExecutable
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: installedExecutable.path
        )
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleShortVersionString": version,
            "CFBundleVersion": String(build),
            "CFBundleExecutable": "InstallerTestApp",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try runTool(
            "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", app.path]
        )
    }

    private static func helperExecutable() throws -> URL {
        let testBundle = Bundle(for: GitHubSoftwareUpdateServiceTests.self)
        let directory = testBundle.bundleURL.deletingLastPathComponent()
        let executable = directory.appendingPathComponent("CodexExportApp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return executable
    }

    private static func runTool(
        _ executable: String,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.executableLoad)
        }
    }
}

private struct UpdateFixture: @unchecked Sendable {
    let repository = "example/codex-export"
    let assetName = "Codex Export 0.3.41.zip"
    let archiveData = Data("PK\u{3}\u{4}fake-update".utf8)
    let manifestData: Data
    let signatureData: Data
    let publicKey: Data
    let releaseData: Data
    let assetSHA256: String

    init(
        prerelease: Bool = false,
        tamperSignature: Bool = false
    ) throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        publicKey = privateKey.publicKey.rawRepresentation
        assetSHA256 = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()

        let manifest: [String: Any] = [
            "schemaVersion": 1,
            "bundleIdentifier": "com.codexexport.menubar",
            "version": "0.3.41",
            "build": 42,
            "assetName": assetName,
            "sha256": assetSHA256,
            "size": archiveData.count,
        ]
        manifestData = try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.sortedKeys]
        )
        var signature = try privateKey.signature(for: manifestData)
        if tamperSignature {
            signature[signature.startIndex] ^= 0xff
        }
        signatureData = signature

        let base = "https://github.com/\(repository)/releases/download/v0.3.41"
        let assets: [[String: Any]] = [
            [
                "name": SoftwareUpdateConfiguration.manifestAssetName,
                "browser_download_url": "\(base)/Codex-Export-update.json",
                "size": manifestData.count,
            ],
            [
                "name": SoftwareUpdateConfiguration.signatureAssetName,
                "browser_download_url": "\(base)/Codex-Export-update.sig",
                "size": signatureData.count,
            ],
            [
                "name": assetName,
                "browser_download_url": "\(base)/Codex%20Export%200.3.41.zip",
                "size": archiveData.count,
            ],
        ]
        releaseData = try JSONSerialization.data(withJSONObject: [
            "tag_name": "v0.3.41",
            "draft": false,
            "prerelease": prerelease,
            "assets": assets,
        ])
    }

    func makeService() -> GitHubSoftwareUpdateService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return GitHubSoftwareUpdateService(
            configuration: SoftwareUpdateConfiguration(
                repository: repository,
                publicKey: publicKey,
                bundleIdentifier: "com.codexexport.menubar",
                targetBundleURL: URL(fileURLWithPath: "/Applications/Codex Export.app")
            ),
            session: URLSession(configuration: configuration)
        )
    }

    func response(for request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let url = try XCTUnwrap(request.url)
        let data: Data
        switch url.lastPathComponent {
        case "latest": data = releaseData
        case SoftwareUpdateConfiguration.manifestAssetName: data = manifestData
        case SoftwareUpdateConfiguration.signatureAssetName: data = signatureData
        default: data = archiveData
        }
        return (
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!,
            data
        )
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func removeHandler() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
