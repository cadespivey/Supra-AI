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
    dependencies: [
        .package(path: "../SupraCore")
    ],
    targets: [
        .target(
            name: "SupraDraftingCore",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore")
            ]
        ),
        .testTarget(
            name: "SupraDraftingCoreTests",
            dependencies: [
                "SupraDraftingCore",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        )
    ]
)
