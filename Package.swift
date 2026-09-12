// swift-tools-version: 6.2

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "swift-mojo",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "Mojo", targets: ["Mojo"]),
        .library(name: "MojoRuntime", targets: ["MojoRuntime"]),
        .library(name: "MojoRuntimeWorker", targets: ["MojoRuntimeWorker"]),
        .library(name: "MojoRuntimeWorkerPOSIX", targets: ["MojoRuntimeWorkerPOSIX"]),
        .plugin(name: "MojoBuildPlugin", targets: ["MojoBuildPlugin"]),
        .plugin(name: "MojoCommandPlugin", targets: ["MojoCommandPlugin"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            exact: "4.5.1"
        ),
        .package(
            url: "https://github.com/swiftlang/swift-syntax.git",
            exact: "603.0.2"
        ),
    ],
    targets: [
        .target(
            name: "MojoBindingCore",
            dependencies: [
                "MojoRuntimeProtocolCore",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(
                    name: "SwiftParserDiagnostics",
                    package: "swift-syntax"
                ),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            exclude: ["DESIGN.md"]
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
            dependencies: ["MojoMacros"],
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "CMojoStaticPreflightFixture",
            path: "Tests/Fixtures/CMojoStaticPreflightFixture",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MojoCompilerCore",
            dependencies: ["MojoPOSIXSupport"]
        ),
        .target(
            name: "CMojoPOSIXSupport",
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "MojoPOSIXSupport",
            dependencies: ["CMojoPOSIXSupport"],
            exclude: ["DESIGN.md"],
            swiftSettings: [
                .enableExperimentalFeature("Extern"),
            ]
        ),
        .target(
            name: "MojoRuntimeProtocolCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "MojoArtifactCore",
            dependencies: [
                "MojoBindingCore",
                "MojoCompilerCore",
                "MojoPOSIXSupport",
                "MojoRuntimeProtocolCore",
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(
                    name: "SwiftParserDiagnostics",
                    package: "swift-syntax"
                ),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "MojoCommandCore",
            dependencies: ["MojoArtifactCore", "MojoCompilerCore"]
        ),
        .target(
            name: "MojoRuntime",
            dependencies: ["MojoArtifactCore", "MojoRuntimeProtocolCore"],
            exclude: ["DESIGN.md"]
        ),
        .target(
            name: "MojoRuntimeWorker",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                "Mojo",
                "MojoRuntime",
                "MojoPOSIXSupport",
                "MojoRuntimeProtocolCore",
            ],
            exclude: ["DESIGN.md", "Input/DESIGN.md", "Lifecycle/DESIGN.md", "Invocation/DESIGN.md"]
        ),
        .target(
            name: "MojoRuntimeWorkerPOSIX",
            dependencies: ["MojoRuntimeWorker", "MojoPOSIXSupport", "MojoRuntimeProtocolCore"],
            exclude: ["DESIGN.md"]
        ),
        .testTarget(
            name: "MojoRuntimeWorkerPOSIXTests",
            dependencies: ["MojoRuntimeWorkerPOSIX", "MojoRuntimeWorker"]
        ),
        .binaryTarget(
            name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
            path: "Generated/MojoBuildPluginIntegrationFixture/SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.xcframework"
        ),
        .binaryTarget(
            name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI_Linux",
            path: "Generated/MojoBuildPluginIntegrationFixture/SwiftMojo_MojoBuildPluginIntegrationFixture_ABI.artifactbundle"
        ),
        .target(
            name: "MojoBuildPluginIntegrationFixture",
            dependencies: [
                "Mojo",
                .target(
                    name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI",
                    condition: .when(platforms: [.macOS])
                ),
                .target(
                    name: "SwiftMojo_MojoBuildPluginIntegrationFixture_ABI_Linux",
                    condition: .when(platforms: [.linux])
                ),
            ],
            plugins: [
                .plugin(name: "MojoBuildPlugin"),
            ]
        ),
        .executableTarget(
            name: "swift-mojo",
            dependencies: ["MojoCommandCore", "MojoPOSIXSupport"]
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
            dependencies: ["swift-mojo"],
            exclude: ["DESIGN.md"]
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
            dependencies: ["Mojo", "CMojoStaticPreflightFixture"]
        ),
        .testTarget(
            name: "MojoCompilerCoreTests",
            dependencies: ["MojoCompilerCore", "MojoPOSIXSupport"]
        ),
        .testTarget(
            name: "MojoPOSIXSupportTests",
            dependencies: ["MojoPOSIXSupport"]
        ),
        .testTarget(
            name: "MojoRuntimeProtocolCoreTests",
            dependencies: ["MojoRuntimeProtocolCore", "CMojoResourceProtocolReference"]
        ),
        .target(
            name: "CMojoResourceProtocolReference",
            path: "Tests/Fixtures/CMojoResourceProtocolReference",
            publicHeadersPath: "include"
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
            name: "MojoRuntimeTests",
            dependencies: [
                "MojoArtifactCore",
                "MojoCompilerCore",
                "MojoRuntime",
            ]
        ),
        .testTarget(
            name: "MojoRuntimeWorkerTests",
            dependencies: [
                "MojoCompilerCore",
                "MojoRuntime",
                "MojoRuntimeProtocolCore",
                "MojoRuntimeWorker",
                "MojoRuntimeWorkerPOSIX",
                "MojoPOSIXSupport",
            ]
        ),
        .testTarget(
            name: "MojoBuildPluginIntegrationTests",
            dependencies: [
                "Mojo",
                "MojoArtifactCore",
                "MojoBuildPluginIntegrationFixture",
            ]
        ),
    ]
)
