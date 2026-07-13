// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraRuntimeInterface",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraRuntimeInterface", targets: ["SupraRuntimeInterface"]),
        .library(
            name: "SupraRuntimeModelSecurity",
            targets: ["SupraRuntimeModelSecurity"]
        )
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
        .target(
            name: "SupraRuntimeModelSecurity",
            dependencies: ["SupraRuntimeInterface"]
        ),
        .testTarget(
            name: "SupraRuntimeInterfaceTests",
            dependencies: [
                "SupraRuntimeInterface",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        ),
        .testTarget(
            name: "SupraRuntimeModelSecurityTests",
            dependencies: [
                "SupraRuntimeModelSecurity",
                "SupraRuntimeInterface"
            ]
        )
    ]
)
