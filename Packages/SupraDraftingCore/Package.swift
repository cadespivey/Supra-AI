// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraDraftingCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraDraftingCore", targets: ["SupraDraftingCore"])
    ],
    targets: [
        .target(name: "SupraDraftingCore"),
        .testTarget(name: "SupraDraftingCoreTests", dependencies: ["SupraDraftingCore"])
    ]
)
