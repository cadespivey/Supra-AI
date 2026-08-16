// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraExports",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraExports", targets: ["SupraExports"]),
        .library(name: "SupraOOXML", targets: ["SupraOOXML"])
    ],
    dependencies: [
        .package(path: "../SupraDraftingCore"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "SupraOOXML",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .target(
            name: "SupraExports",
            dependencies: [
                "SupraOOXML",
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
            ]
        ),
        .testTarget(
            name: "SupraExportsTests",
            dependencies: [
                "SupraExports",
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
