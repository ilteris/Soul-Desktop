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
        .library(name: "SoulLedger", targets: ["SoulLedger"]),
        .library(name: "SoulRuntime", targets: ["SoulRuntime"])
    ],
    targets: [
        .target(
            name: "SoulCore"
        ),
        .target(
            name: "SoulACP",
            dependencies: ["SoulCore"]
        ),
        .target(
            name: "SoulLedger",
            dependencies: ["SoulCore"]
        ),
        .target(
            name: "SoulRuntime",
            dependencies: ["SoulCore", "SoulACP"]
        ),
        .testTarget(
            name: "SoulACPTests",
            dependencies: ["SoulACP"]
        ),
        .testTarget(
            name: "SoulCoreTests",
            dependencies: ["SoulCore"]
        ),
        .testTarget(
            name: "SoulLedgerTests",
            dependencies: ["SoulLedger"]
        ),
        .testTarget(
            name: "SoulRuntimeTests",
            dependencies: ["SoulRuntime"]
        )
    ]
)
