// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraDocuments",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraDocuments", targets: ["SupraDocuments"])
    ],
    dependencies: [
        .package(path: "../SupraCore")
    ],
    targets: [
        .target(
            name: "SupraDocuments",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore")
            ]
        ),
        .testTarget(
            name: "SupraDocumentsTests",
            dependencies: [
                "SupraDocuments",
                .product(name: "SupraCore", package: "SupraCore")
            ]
        )
    ]
)
