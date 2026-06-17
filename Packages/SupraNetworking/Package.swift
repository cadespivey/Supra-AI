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
        .package(path: "../SupraCore"),
        .package(path: "../SupraStore")
    ],
    targets: [
        .target(
            name: "SupraNetworking",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "SupraNetworkingTests",
            dependencies: [
                "SupraNetworking",
                .product(name: "SupraStore", package: "SupraStore")
            ]
        )
    ]
)
