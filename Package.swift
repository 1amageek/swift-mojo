// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "swift-mojo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "Mojo", targets: ["Mojo"]),
        .executable(name: "swift-mojo", targets: ["swift-mojo"]),
        .plugin(name: "MojoBuildPlugin", targets: ["MojoBuildPlugin"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            revision: "swift-6.4.x-DEVELOPMENT-SNAPSHOT-2026-08-14-a"
        ),
    ],
    targets: [
        .target(
            name: "MojoBindingCore",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .macro(
            name: "MojoMacros",
            dependencies: [
                "MojoBindingCore",
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "Mojo",
            dependencies: ["MojoMacros"]
        ),
        .target(name: "MojoCompilerCore"),
        .target(
            name: "MojoArtifactCore",
            dependencies: ["MojoBindingCore", "MojoCompilerCore"]
        ),
        .executableTarget(
            name: "swift-mojo",
            dependencies: ["MojoArtifactCore"]
        ),
        .plugin(
            name: "MojoBuildPlugin",
            capability: .buildTool(),
            dependencies: ["swift-mojo"]
        ),
        .testTarget(
            name: "MojoMacroTests",
            dependencies: [
                "MojoMacros",
                .product(
                    name: "SwiftSyntaxMacrosTestSupport",
                    package: "swift-syntax"
                ),
            ]
        ),
        .testTarget(
            name: "MojoCompilerCoreTests",
            dependencies: ["MojoCompilerCore"]
        ),
        .testTarget(
            name: "MojoBindingCoreTests",
            dependencies: ["MojoBindingCore"]
        ),
        .testTarget(
            name: "MojoArtifactCoreTests",
            dependencies: [
                "MojoArtifactCore",
                "MojoBindingCore",
                "MojoCompilerCore",
            ]
        ),
        .testTarget(
            name: "MojoBuildPluginIntegrationTests",
            dependencies: [
                "MojoArtifactCore",
                "MojoBindingCore",
                "MojoCompilerCore",
            ]
        ),
    ]
)
