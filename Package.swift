// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexExport",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CodexExportApp",
            targets: ["CodexExportApp"]
        )
    ],
    targets: [
        .target(
            name: "CodexExportCore",
            path: "Sources/CodexExportCore"
        ),
        .target(
            name: "CodexExportFeature",
            dependencies: ["CodexExportCore"]
        ),
        .executableTarget(
            name: "CodexExportApp",
            dependencies: ["CodexExportCore", "CodexExportFeature"]
        ),
        .testTarget(
            name: "CodexExportCoreTests",
            dependencies: ["CodexExportCore"]
        ),
        .testTarget(
            name: "CodexExportFeatureTests",
            dependencies: ["CodexExportCore", "CodexExportFeature"]
        ),
        .testTarget(
            name: "CodexExportAppTests",
            dependencies: [
                "CodexExportApp",
                "CodexExportCore",
                "CodexExportFeature",
            ]
        )
    ]
)
