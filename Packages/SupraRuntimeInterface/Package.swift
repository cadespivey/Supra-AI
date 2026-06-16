// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraRuntimeInterface",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraRuntimeInterface", targets: ["SupraRuntimeInterface"])
    ],
    dependencies: [
        .package(path: "../SupraCore")
    ],
    targets: [
        .target(
            name: "SupraRuntimeInterface",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore")
            ]
        ),
        .testTarget(
            name: "SupraRuntimeInterfaceTests",
            dependencies: [
                "SupraRuntimeInterface",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        )
    ]
)
