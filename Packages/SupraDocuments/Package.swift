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
        .package(path: "../SupraCore"),
        // Pinned local archive reader for Office Open XML (.docx) and
        // spreadsheet (.xlsx) containers. MIT; runs locally, no network.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20")
    ],
    targets: [
        .target(
            name: "SupraDocuments",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "SupraDocumentsTests",
            dependencies: [
                "SupraDocuments",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        )
    ]
)
