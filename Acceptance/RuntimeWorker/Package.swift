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
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            exclude: ["SourceIdentity/DESIGN.md"]
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
