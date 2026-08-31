// swift-tools-version: 6.2

import Foundation
import PackageDescription

let swiftMojoPackagePath = ProcessInfo.processInfo.environment[
    "SWIFT_MOJO_REPOSITORY_ROOT"
] ?? "../.."

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
        .executable(
            name: "runtime-worker-acceptance-source",
            targets: ["RuntimeWorkerAcceptanceSourceRunner"]
        ),
        .executable(
            name: "RuntimeWorkerAcceptanceConsumer",
            targets: ["RuntimeWorkerAcceptanceConsumer"]
        ),
    ],
    dependencies: [
        .package(path: swiftMojoPackagePath),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
    ],
    targets: [
        .target(
            name: "RuntimeWorkerAcceptance",
            dependencies: [
                .product(name: "MojoRuntime", package: "swift-mojo"),
                .product(name: "MojoRuntimeWorker", package: "swift-mojo"),
                "RuntimeWorkerAcceptanceSourceIdentity",
            ]
        ),
        .target(
            name: "RuntimeWorkerAcceptanceSourceIdentity",
            dependencies: [
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux])
                ),
            ],
            path: "Sources/RuntimeWorkerAcceptanceSourceIdentity",
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "RuntimeWorkerAcceptanceModel",
            path: "Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel",
            exclude: ["Bindings.swift"]
        ),
        .executableTarget(
            name: "RuntimeWorkerAcceptanceConsumer",
            dependencies: [
                .product(name: "MojoRuntime", package: "swift-mojo"),
                .product(name: "MojoRuntimeWorker", package: "swift-mojo"),
            ],
            path: "Fixtures/Consumer/Sources/RuntimeWorkerAcceptanceConsumer"
        ),
        .executableTarget(
            name: "RuntimeWorkerAcceptanceRunner",
            dependencies: [
                "RuntimeWorkerAcceptance",
                "RuntimeWorkerAcceptanceSourceIdentity",
            ]
        ),
        .executableTarget(
            name: "RuntimeWorkerAcceptanceSourceRunner",
            dependencies: ["RuntimeWorkerAcceptanceSourceIdentity"],
            path: "Sources/RuntimeWorkerAcceptanceSourceRunner",
            exclude: ["DESIGN.md"]
        ),
        .testTarget(
            name: "RuntimeWorkerAcceptanceTests",
            dependencies: [
                "RuntimeWorkerAcceptance",
                "RuntimeWorkerAcceptanceSourceIdentity",
            ]
        ),
    ]
)
