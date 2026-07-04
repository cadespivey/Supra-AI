// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraResearch",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraResearch", targets: ["SupraResearch"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraNetworking")
    ],
    targets: [
        .target(
            name: "SupraResearch",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraNetworking", package: "SupraNetworking")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SupraResearchTests",
            dependencies: ["SupraResearch"],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
