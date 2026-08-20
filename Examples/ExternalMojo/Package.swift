// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "InlineMojoExample",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "swift-mojo", path: "../.."),
    ],
    targets: [
        .binaryTarget(
            name: "GeneratedMojoABI",
            path: "Generated/ExternalMojo/GeneratedMojoABI.xcframework"
        ),
        .executableTarget(
            name: "ExternalMojo",
            dependencies: [
                .product(name: "Mojo", package: "swift-mojo"),
                "GeneratedMojoABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
            ]
        ),
    ]
)
