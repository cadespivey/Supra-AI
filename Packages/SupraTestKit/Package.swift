// swift-tools-version: 6.0

import PackageDescription

// Isolated developer test-seeding package. NOT part of SupraAI.xcworkspace, so it
// never affects the app build. Generates a realistic document corpus (the
// `SeedCorpus` executable) and runs end-to-end pipeline validation over it.
let package = Package(
    name: "SupraTestKit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraTestKit", targets: ["SupraTestKit"]),
        .executable(name: "SeedCorpus", targets: ["SeedCorpus"]),
        .executable(name: "SupraBench", targets: ["SupraBench"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraStore"),
        .package(path: "../SupraDocuments"),
        .package(path: "../SupraSessions"),
        .package(path: "../SupraResearch"),
        .package(path: "../SupraDrafting"),
        .package(path: "../SupraDraftingCore"),
        .package(path: "../SupraNetworking"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "SupraTestKit",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraDocuments", package: "SupraDocuments"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .executableTarget(
            name: "SeedCorpus",
            dependencies: ["SupraTestKit"]
        ),
        .executableTarget(
            name: "SupraBench",
            dependencies: [
                "SupraTestKit",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraDocuments", package: "SupraDocuments"),
                .product(name: "SupraSessions", package: "SupraSessions")
            ]
        ),
        .testTarget(
            name: "SupraTestKitTests",
            dependencies: [
                "SupraTestKit",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraDocuments", package: "SupraDocuments"),
                .product(name: "SupraSessions", package: "SupraSessions"),
                .product(name: "SupraResearch", package: "SupraResearch"),
                .product(name: "SupraDrafting", package: "SupraDrafting"),
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "SupraNetworking", package: "SupraNetworking")
            ],
            resources: [.copy("Fixtures")]
        )
    ]
)
