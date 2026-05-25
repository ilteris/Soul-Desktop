// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SoulDesktopModules",
    platforms: [
        .macOS("26.3")
    ],
    products: [
        .library(name: "SoulCore", targets: ["SoulCore"]),
        .library(name: "SoulACP", targets: ["SoulACP"]),
        .library(name: "SoulLedger", targets: ["SoulLedger"])
    ],
    targets: [
        .target(
            name: "SoulCore",
            path: "Sources/SoulCore"
        ),
        .target(
            name: "SoulACP",
            dependencies: ["SoulCore"],
            path: "Sources/SoulACP"
        ),
        .target(
            name: "SoulLedger",
            path: "Sources/SoulLedger"
        ),
        .testTarget(
            name: "SoulACPTests",
            dependencies: ["SoulACP"],
            path: "Tests/SoulACPTests"
        ),
        .testTarget(
            name: "SoulCoreTests",
            dependencies: ["SoulCore"],
            path: "Tests/SoulCoreTests"
        ),
        .testTarget(
            name: "SoulLedgerTests",
            dependencies: ["SoulLedger"],
            path: "Tests/SoulLedgerTests"
        )
    ]
)
