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
        .package(path: "../SupraCore"),
        .package(path: "../SupraDraftingCore"),
        .package(path: "../SupraExports")
    ],
    targets: [
        .target(
            name: "SupraDrafting",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore")
            ]
        ),
        .testTarget(
            name: "SupraDraftingTests",
            dependencies: [
                "SupraDrafting",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "SupraExports", package: "SupraExports")
            ]
        )
    ]
)
