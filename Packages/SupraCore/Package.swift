// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraCore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraCore", targets: ["SupraCore"])
    ],
    targets: [
        .target(name: "SupraCore"),
        .testTarget(name: "SupraCoreTests", dependencies: ["SupraCore"])
    ]
)
