// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraStore",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraStore", targets: ["SupraStore"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraDiagnostics"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.0")
    ],
    targets: [
        .target(
            name: "SupraStore",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraDiagnostics", package: "SupraDiagnostics"),
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .testTarget(
            name: "SupraStoreTests",
            dependencies: [
                "SupraStore",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        )
    ]
)
