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
        .executable(
            name: "runtime-worker-acceptance",
            targets: ["RuntimeWorkerAcceptanceRunner"]
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
                .product(name: "MojoRuntimeWorker", package: "swift-mojo"),
            ]
        ),
        .executableTarget(
            name: "RuntimeWorkerAcceptanceRunner",
            dependencies: ["RuntimeWorkerAcceptance"]
        ),
        .testTarget(
            name: "RuntimeWorkerAcceptanceTests",
            dependencies: ["RuntimeWorkerAcceptance"]
        ),
    ]
)
