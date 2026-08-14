// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraNetworking",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraNetworking", targets: ["SupraNetworking"])
    ],
    dependencies: [
        .package(path: "../SupraCore")
    ],
    targets: [
        .target(
            name: "SupraNetworking",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "SupraNetworkingTests",
            dependencies: [
                "SupraNetworking",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        )
    ]
)
