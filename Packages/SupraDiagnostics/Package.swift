// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SupraDiagnostics",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SupraDiagnostics", targets: ["SupraDiagnostics"])
    ],
    dependencies: [
        .package(path: "../SupraCore"),
        .package(path: "../SupraRuntimeInterface")
    ],
    targets: [
        .target(
            name: "SupraDiagnostics",
            dependencies: [
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface")
            ]
        ),
        .testTarget(
            name: "SupraDiagnosticsTests",
            dependencies: [
                "SupraDiagnostics",
                .product(name: "SupraCore", package: "SupraCore"),
                .product(name: "SupraRuntimeInterface", package: "SupraRuntimeInterface")
            ]
        )
    ]
)
