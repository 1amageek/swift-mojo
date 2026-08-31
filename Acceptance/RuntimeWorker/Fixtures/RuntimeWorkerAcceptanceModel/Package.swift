// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeWorkerAcceptanceModel",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../.."),
    ],
    targets: [
        .target(
            name: "RuntimeWorkerAcceptanceModel",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
            ]
        ),
    ]
)
