// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraExports",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraExports", targets: ["SupraExports"])
    ],
    dependencies: [
        .package(path: "../SupraDraftingCore"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "SupraExports",
            dependencies: [
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
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
