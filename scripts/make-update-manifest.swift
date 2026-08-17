#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let usage = """
Usage:
  swift scripts/make-update-manifest.swift \\
    --version-file <VERSION> \\
    --zip <release.zip> \\
    --bundle-id <bundle.identifier> \\
    [--manifest <Codex-Export-update.json>] \\
    [--signature <Codex-Export-update.sig>]

The default outputs are Codex-Export-update.json and Codex-Export-update.sig
beside the ZIP. The signature file contains the raw 64-byte detached Ed25519
signature. CODEX_EXPORT_UPDATE_PRIVATE_KEY must contain the canonical base64
encoding of a Curve25519.Signing.PrivateKey raw representation.
"""

private enum ToolError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private struct Options {
    let versionFile: URL
    let zip: URL
    let bundleIdentifier: String
    let manifest: URL
    let signature: URL

    static func parse(_ arguments: [String]) throws -> Options? {
        if arguments == ["--help"] || arguments == ["-h"] {
            print(usage)
            return nil
        }

        let valueOptions: Set<String> = [
            "--version-file",
            "--zip",
            "--bundle-id",
            "--manifest",
            "--signature",
        ]
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let option = arguments[index]
            guard valueOptions.contains(option) else {
                throw ToolError.message("Unknown argument: \(option)\n\n\(usage)")
            }
            guard values[option] == nil else {
                throw ToolError.message("Duplicate argument: \(option)")
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw ToolError.message("Missing value for \(option)")
            }
            let value = arguments[valueIndex]
            guard !value.isEmpty, !valueOptions.contains(value) else {
                throw ToolError.message("Missing value for \(option)")
            }
            values[option] = value
            index += 2
        }

        func required(_ option: String) throws -> String {
            guard let value = values[option] else {
                throw ToolError.message("Missing required argument: \(option)\n\n\(usage)")
            }
            return value
        }

        let versionFile = absoluteURL(for: try required("--version-file"))
        let zip = absoluteURL(for: try required("--zip"))
        let bundleIdentifier = try required("--bundle-id")
        let outputDirectory = zip.deletingLastPathComponent()
        let manifest = absoluteURL(
            for: values["--manifest"]
                ?? outputDirectory.appendingPathComponent(
                    "Codex-Export-update.json"
                ).path
        )
        let defaultSignature = manifest
            .deletingPathExtension()
            .appendingPathExtension("sig")
        let signature = absoluteURL(
            for: values["--signature"] ?? defaultSignature.path
        )

        return Options(
            versionFile: versionFile,
            zip: zip,
            bundleIdentifier: bundleIdentifier,
            manifest: manifest,
            signature: signature
        )
    }
}

private struct ProjectVersion {
    let version: String
    let build: UInt64
}

private struct Manifest: Encodable {
    let schemaVersion: Int
    let bundleIdentifier: String
    let version: String
    let build: UInt64
    let assetName: String
    let sha256: String
    let size: UInt64
}

private struct AssetDigest {
    let sha256: String
    let size: UInt64
}

private func absoluteURL(for path: String) -> URL {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }
    return URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    .appendingPathComponent(expanded)
    .standardizedFileURL
}

private func parseVersion(at url: URL) throws -> ProjectVersion {
    let data: Data
    do {
        data = try Data(contentsOf: url, options: [.mappedIfSafe])
    } catch {
        throw ToolError.message("Cannot read VERSION at \(url.path): \(error)")
    }
    guard let contents = String(data: data, encoding: .utf8) else {
        throw ToolError.message("VERSION is not valid UTF-8: \(url.path)")
    }

    var values: [String: String] = [:]
    for rawLine in contents.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        guard let separator = line.firstIndex(of: "=") else {
            throw ToolError.message("Malformed VERSION line: \(rawLine)")
        }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard key == "MARKETING_VERSION" || key == "BUILD_NUMBER" else {
            throw ToolError.message("Unknown VERSION key: \(key)")
        }
        guard values[key] == nil else {
            throw ToolError.message("Duplicate VERSION key: \(key)")
        }
        guard !value.isEmpty else {
            throw ToolError.message("Empty VERSION value for \(key)")
        }
        values[key] = value
    }

    guard let version = values["MARKETING_VERSION"] else {
        throw ToolError.message("VERSION is missing MARKETING_VERSION")
    }
    guard version.range(
        of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#,
        options: .regularExpression
    ) != nil else {
        throw ToolError.message("Invalid MARKETING_VERSION: \(version)")
    }
    guard let buildText = values["BUILD_NUMBER"],
          buildText.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil,
          let build = UInt64(buildText) else {
        throw ToolError.message("Invalid or missing BUILD_NUMBER")
    }
    return ProjectVersion(version: version, build: build)
}

private func validateBundleIdentifier(_ identifier: String) throws {
    let components = identifier.split(separator: ".", omittingEmptySubsequences: false)
    let componentPattern = #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#
    guard components.count >= 2,
          components.allSatisfy({ component in
              String(component).range(
                  of: componentPattern,
                  options: .regularExpression
              ) != nil
          }) else {
        throw ToolError.message("Invalid bundle identifier: \(identifier)")
    }
}

private func digestZIP(at url: URL) throws -> AssetDigest {
    guard url.pathExtension.lowercased() == "zip" else {
        throw ToolError.message("Asset must have a .zip extension: \(url.path)")
    }
    let assetName = url.lastPathComponent
    guard !assetName.isEmpty,
          assetName != ".",
          assetName != "..",
          !assetName.contains("/"),
          !assetName.contains("\\"),
          !assetName.utf8.contains(0) else {
        throw ToolError.message("ZIP has an unsafe asset name: \(assetName)")
    }

    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: url)
    } catch {
        throw ToolError.message("Cannot open ZIP at \(url.path): \(error)")
    }
    defer { try? handle.close() }

    var before = stat()
    guard fstat(handle.fileDescriptor, &before) == 0 else {
        throw ToolError.message("Cannot inspect ZIP at \(url.path)")
    }
    guard (before.st_mode & S_IFMT) == S_IFREG, before.st_size > 0 else {
        throw ToolError.message("ZIP must be a non-empty regular file: \(url.path)")
    }

    let header: Data
    do {
        header = try handle.read(upToCount: 4) ?? Data()
    } catch {
        throw ToolError.message("Cannot read ZIP header at \(url.path): \(error)")
    }
    let acceptedHeaders: Set<[UInt8]> = [
        [0x50, 0x4b, 0x03, 0x04],
        [0x50, 0x4b, 0x05, 0x06],
        [0x50, 0x4b, 0x07, 0x08],
    ]
    guard acceptedHeaders.contains(Array(header)) else {
        throw ToolError.message("Asset does not have a recognized ZIP header: \(url.path)")
    }

    do {
        try handle.seek(toOffset: 0)
    } catch {
        throw ToolError.message("Cannot rewind ZIP at \(url.path): \(error)")
    }

    var hasher = SHA256()
    var byteCount: UInt64 = 0
    while true {
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 1_048_576) ?? Data()
        } catch {
            throw ToolError.message("Cannot read ZIP at \(url.path): \(error)")
        }
        if chunk.isEmpty {
            break
        }
        let (nextCount, overflow) = byteCount.addingReportingOverflow(UInt64(chunk.count))
        guard !overflow else {
            throw ToolError.message("ZIP is too large to describe safely: \(url.path)")
        }
        byteCount = nextCount
        hasher.update(data: chunk)
    }

    var after = stat()
    guard fstat(handle.fileDescriptor, &after) == 0 else {
        throw ToolError.message("Cannot re-inspect ZIP at \(url.path)")
    }
    guard before.st_dev == after.st_dev,
          before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
          before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
          byteCount == UInt64(after.st_size) else {
        throw ToolError.message("ZIP changed while it was being hashed: \(url.path)")
    }

    let hexadecimal = Array("0123456789abcdef".utf8)
    var hashBytes: [UInt8] = []
    hashBytes.reserveCapacity(SHA256.byteCount * 2)
    for byte in hasher.finalize() {
        hashBytes.append(hexadecimal[Int(byte >> 4)])
        hashBytes.append(hexadecimal[Int(byte & 0x0f)])
    }
    guard let hash = String(bytes: hashBytes, encoding: .utf8) else {
        throw ToolError.message("Could not encode the SHA-256 digest")
    }
    return AssetDigest(sha256: hash, size: byteCount)
}

private func signingKey() throws -> Curve25519.Signing.PrivateKey {
    guard let supplied = ProcessInfo.processInfo.environment[
        "CODEX_EXPORT_UPDATE_PRIVATE_KEY"
    ] else {
        throw ToolError.message(
            "CODEX_EXPORT_UPDATE_PRIVATE_KEY is not set"
        )
    }
    let encoded = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !encoded.isEmpty,
          let rawKey = Data(base64Encoded: encoded),
          rawKey.base64EncodedString() == encoded else {
        throw ToolError.message(
            "CODEX_EXPORT_UPDATE_PRIVATE_KEY is not canonical base64"
        )
    }
    let key: Curve25519.Signing.PrivateKey
    do {
        key = try Curve25519.Signing.PrivateKey(rawRepresentation: rawKey)
    } catch {
        throw ToolError.message(
            "CODEX_EXPORT_UPDATE_PRIVATE_KEY is not a valid signing private key"
        )
    }
    if let suppliedPublicKey = ProcessInfo.processInfo.environment[
        "CODEX_EXPORT_UPDATE_PUBLIC_KEY"
    ] {
        let encodedPublicKey = suppliedPublicKey.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let publicKey = Data(base64Encoded: encodedPublicKey),
              publicKey.base64EncodedString() == encodedPublicKey,
              publicKey == key.publicKey.rawRepresentation else {
            throw ToolError.message(
                "CODEX_EXPORT_UPDATE_PUBLIC_KEY does not match the signing private key"
            )
        }
    }
    return key
}

private func validateOutputPaths(_ options: Options) throws {
    let inputPaths = Set([options.versionFile.path, options.zip.path])
    guard options.manifest.path != options.signature.path else {
        throw ToolError.message("Manifest and signature paths must differ")
    }
    guard !inputPaths.contains(options.manifest.path),
          !inputPaths.contains(options.signature.path) else {
        throw ToolError.message("An output path overlaps an input path")
    }

    for output in [options.manifest, options.signature] {
        let parent = output.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw ToolError.message("Output directory does not exist: \(parent.path)")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           attributes[.type] as? FileAttributeType == .typeDirectory {
            throw ToolError.message("Output path is a directory: \(output.path)")
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: output.path),
           attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw ToolError.message("Refusing to replace symbolic-link output: \(output.path)")
        }
    }
}

private func run() throws {
    guard let options = try Options.parse(Array(CommandLine.arguments.dropFirst())) else {
        return
    }
    try validateBundleIdentifier(options.bundleIdentifier)
    try validateOutputPaths(options)
    let version = try parseVersion(at: options.versionFile)
    let digest = try digestZIP(at: options.zip)
    let key = try signingKey()

    let manifest = Manifest(
        schemaVersion: 1,
        bundleIdentifier: options.bundleIdentifier,
        version: version.version,
        build: version.build,
        assetName: options.zip.lastPathComponent,
        sha256: digest.sha256,
        size: digest.size
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var manifestData: Data
    do {
        manifestData = try encoder.encode(manifest)
    } catch {
        throw ToolError.message("Could not encode update manifest: \(error)")
    }
    manifestData.append(0x0a)

    let signature: Data
    do {
        signature = try key.signature(for: manifestData)
    } catch {
        throw ToolError.message("Could not sign update manifest: \(error)")
    }
    guard signature.count == 64,
          key.publicKey.isValidSignature(signature, for: manifestData) else {
        throw ToolError.message("Generated signature failed self-verification")
    }

    do {
        try manifestData.write(to: options.manifest, options: .atomic)
        try signature.write(to: options.signature, options: .atomic)
    } catch {
        throw ToolError.message("Could not write signed manifest outputs: \(error)")
    }

    print("manifest=\(options.manifest.path)")
    print("signature=\(options.signature.path)")
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
