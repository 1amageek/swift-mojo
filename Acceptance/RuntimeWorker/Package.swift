// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeWorkerAcceptance",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "RuntimeWorkerAcceptance",
            targets: ["RuntimeWorkerAcceptance"]
        ),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "RuntimeWorkerAcceptance",
            dependencies: [
                .product(name: "MojoRuntime", package: "swift-mojo"),
            ]
        ),
        .testTarget(
            name: "RuntimeWorkerAcceptanceTests",
            dependencies: ["RuntimeWorkerAcceptance"]
        ),
    ]
)
