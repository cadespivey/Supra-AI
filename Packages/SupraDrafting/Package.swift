// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraDrafting",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraDrafting", targets: ["SupraDrafting"])
    ],
    dependencies: [
        .package(path: "../SupraDraftingCore")
    ],
    targets: [
        .target(
            name: "SupraDrafting",
            dependencies: [
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore")
            ]
        ),
        .testTarget(
            name: "SupraDraftingTests",
            dependencies: [
                "SupraDrafting",
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore")
            ]
        )
    ]
)
