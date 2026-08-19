// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "codex-micro-wispr-bridge",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "codex-micro-wispr-bridge",
            targets: ["CodexMicroWisprBridge"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodexMicroWisprBridge",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("IOKit")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
