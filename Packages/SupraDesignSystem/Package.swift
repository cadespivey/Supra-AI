// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraDesignSystem",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraDesignSystem", targets: ["SupraDesignSystem"])
    ],
    targets: [
        .target(name: "SupraDesignSystem"),
        .testTarget(name: "SupraDesignSystemTests", dependencies: ["SupraDesignSystem"])
    ]
)
