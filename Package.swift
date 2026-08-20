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
        .plugin(name: "MojoBuildPlugin", targets: ["MojoBuildPlugin"]),
        .plugin(name: "MojoCommandPlugin", targets: ["MojoCommandPlugin"]),
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
                .product(
                    name: "SwiftParserDiagnostics",
                    package: "swift-syntax"
                ),
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
            dependencies: [
                "MojoBindingCore",
                "MojoCompilerCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(
                    name: "SwiftParserDiagnostics",
                    package: "swift-syntax"
                ),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ]
        ),
        .target(
            name: "MojoCommandCore",
            dependencies: ["MojoArtifactCore", "MojoCompilerCore"]
        ),
        .binaryTarget(
            name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
            path: "Generated/MojoBuildPluginIntegrationFixture/SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.xcframework"
        ),
        .target(
            name: "MojoBuildPluginIntegrationFixture",
            dependencies: [
                "Mojo",
                "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin"),
            ]
        ),
        .executableTarget(
            name: "swift-mojo",
            dependencies: ["MojoCommandCore"]
        ),
        .plugin(
            name: "MojoBuildPlugin",
            capability: .buildTool(),
            dependencies: ["swift-mojo"]
        ),
        .plugin(
            name: "MojoCommandPlugin",
            capability: .command(
                intent: .custom(
                    verb: "mojo",
                    description: "Prepare and validate Mojo artifacts"
                ),
                permissions: [
                    .writeToPackageDirectory(
                        reason: "Prepare versioned Mojo artifacts"
                    ),
                ]
            ),
            dependencies: ["swift-mojo"]
        ),
        .testTarget(
            name: "MojoMacroTests",
            dependencies: [
                "MojoMacros",
                "MojoBindingCore",
                .product(
                    name: "SwiftSyntaxMacrosTestSupport",
                    package: "swift-syntax"
                ),
            ]
        ),
        .testTarget(
            name: "MojoTests",
            dependencies: ["Mojo"]
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
            name: "MojoCommandCoreTests",
            dependencies: ["MojoArtifactCore", "MojoCommandCore"]
        ),
        .testTarget(
            name: "MojoBuildPluginIntegrationTests",
            dependencies: ["MojoBuildPluginIntegrationFixture"]
        ),
    ]
)
