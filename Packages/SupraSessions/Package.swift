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
        .package(path: "../SupraRuntimeClient"),
        .package(path: "../SupraDiagnostics"),
        .package(path: "../SupraResearch"),
        .package(path: "../SupraNetworking"),
        .package(path: "../SupraDocuments"),
        .package(path: "../SupraDraftingCore"),
        .package(path: "../SupraDrafting"),
        .package(path: "../SupraExports")
    ],
    targets: [
        .target(
            name: "SupraSessions",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface"),
                .product(name: "SupraRuntimeClient", package: "SupraRuntimeClient"),
                .product(name: "SupraDiagnostics", package: "SupraDiagnostics"),
                .product(name: "SupraResearch", package: "SupraResearch"),
                .product(name: "SupraNetworking", package: "SupraNetworking"),
                .product(name: "SupraDocuments", package: "SupraDocuments"),
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "SupraDrafting", package: "SupraDrafting"),
                .product(name: "SupraExports", package: "SupraExports")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "SupraSessionsTests",
            dependencies: [
                "SupraSessions",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraStore", package: "SupraStore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface"),
                .product(name: "SupraRuntimeClient", package: "SupraRuntimeClient"),
                .product(name: "SupraDiagnostics", package: "SupraDiagnostics"),
                .product(name: "SupraResearch", package: "SupraResearch"),
                .product(name: "SupraNetworking", package: "SupraNetworking"),
                .product(name: "SupraDocuments", package: "SupraDocuments"),
                .product(name: "SupraDraftingCore", package: "SupraDraftingCore"),
                .product(name: "SupraDrafting", package: "SupraDrafting"),
                .product(name: "SupraExports", package: "SupraExports")
            ]
        )
    ]
)
