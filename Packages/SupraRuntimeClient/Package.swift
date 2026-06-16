// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraRuntimeClient",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraRuntimeClient", targets: ["SupraRuntimeClient"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraRuntimeInterface")
    ],
    targets: [
        .target(
            name: "SupraRuntimeClient",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface")
            ]
        ),
        .testTarget(
            name: "SupraRuntimeClientTests",
            dependencies: [
                "SupraRuntimeClient",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface")
            ]
        )
    ]
)
