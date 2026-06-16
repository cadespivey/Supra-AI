// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraSessions",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraSessions", targets: ["SupraSessions"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraStore"),
        .package(path: "../SupraRuntimeInterface"),
        .package(path: "../SupraRuntimeClient")
    ],
    targets: [
        .target(
            name: "SupraSessions",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface"),
                .product(name: "SupraRuntimeClient", package: "SupraRuntimeClient")
            ]
        ),
        .testTarget(
            name: "SupraSessionsTests",
            dependencies: [
                "SupraSessions",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface"),
                .product(name: "SupraRuntimeClient", package: "SupraRuntimeClient")
            ]
        )
    ]
)
