#!/usr/bin/env swift

import CryptoKit
import Darwin
import Foundation

private let usage = """
Usage:
  swift scripts/generate-update-key.swift

Prints a newly generated Curve25519.Signing key pair as canonical base64.
The private key is printed only to standard output; store it in a secret manager
as CODEX_EXPORT_UPDATE_PRIVATE_KEY and do not commit it to the repository.
"""

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] || arguments == ["-h"] {
    print(usage)
    exit(EXIT_SUCCESS)
}
guard arguments.isEmpty else {
    FileHandle.standardError.write(
        Data("error: unexpected arguments\n\n\(usage)\n".utf8)
    )
    exit(EXIT_FAILURE)
}

let privateKey = Curve25519.Signing.PrivateKey()
print(
    "CODEX_EXPORT_UPDATE_PUBLIC_KEY="
        + privateKey.publicKey.rawRepresentation.base64EncodedString()
)
print(
    "CODEX_EXPORT_UPDATE_PRIVATE_KEY="
        + privateKey.rawRepresentation.base64EncodedString()
)
