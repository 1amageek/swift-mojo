// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RuntimeWorkerAcceptanceConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "../../../.."),
    ],
    targets: [
        .executableTarget(
            name: "RuntimeWorkerAcceptanceConsumer",
            dependencies: [
                .product(name: "MojoRuntime", package: "swift-mojo"),
                .product(name: "MojoRuntimeWorker", package: "swift-mojo"),
            ]
        ),
    ]
)
