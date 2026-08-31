// swift-tools-version: 6.2

import Foundation
import PackageDescription

let swiftMojoPackagePath = ProcessInfo.processInfo.environment[
    "SWIFT_MOJO_REPOSITORY_ROOT"
] ?? "../../../.."

let package = Package(
    name: "RuntimeWorkerAcceptanceModel",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: swiftMojoPackagePath),
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
