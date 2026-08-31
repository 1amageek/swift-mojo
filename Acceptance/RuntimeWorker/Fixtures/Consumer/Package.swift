// swift-tools-version: 6.2

import Foundation
import PackageDescription

let swiftMojoPackagePath = ProcessInfo.processInfo.environment[
    "SWIFT_MOJO_REPOSITORY_ROOT"
] ?? "../../../.."

let package = Package(
    name: "RuntimeWorkerAcceptanceConsumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: swiftMojoPackagePath),
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
