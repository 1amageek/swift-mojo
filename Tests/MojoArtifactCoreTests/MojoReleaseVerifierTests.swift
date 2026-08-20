import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

@Suite("Mojo release verification")
struct MojoReleaseVerifierTests {
    private struct Fixture {
        let root: URL
        let layout: MojoPackageLayout
        let configuration: SwiftMojoConfiguration
        let generatedSourceURL: URL
        let sourceMapURL: URL

        init(localDependency: Bool = false) throws {
            let fileManager = FileManager.default
            root = fileManager.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            let sourceRoot = root.appendingPathComponent(
                "Sources/Model",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: sourceRoot,
                withIntermediateDirectories: true
            )
            let dependencies = localDependency
                ? """
                dependencies: [
                    .package(path: "../Local"),
                    .package(
                        url: "https://github.com/1amageek/swift-mojo.git",
                        revision: "candidate-revision"
                    ),
                ],
                """
                : """
                dependencies: [
                    .package(
                        url: "https://github.com/1amageek/swift-mojo.git",
                        revision: "candidate-revision"
                    ),
                ],
                """
            try """
            // swift-tools-version: 6.2
            import PackageDescription
            let package = Package(
                name: "Fixture",
                \(dependencies)
                targets: [
                    .binaryTarget(
                        name: "SwiftMojo_Model_ABI",
                        path: "Generated/Model/SwiftMojo_Model_ABI.xcframework"
                    ),
                    .target(
                        name: "Model",
                        dependencies: [
                            .product(name: "Mojo", package: "swift-mojo"),
                            "SwiftMojo_Model_ABI",
                        ],
                        plugins: [
                            .plugin(
                                name: "MojoBuildPlugin",
                                package: "swift-mojo"
                            )
                        ]
                    ),
                ]
            )
            """.write(
                to: root.appendingPathComponent("Package.swift"),
                atomically: true,
                encoding: .utf8
            )
            let sourceURL = sourceRoot.appendingPathComponent("Bindings.swift")
            try """
            import Mojo

            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                return a + b
            }
            """.write(to: sourceURL, atomically: true, encoding: .utf8)

            layout = try MojoPackageLayout(
                packageRootURL: root,
                targetName: "Model"
            )
            let target = try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "generic"
            )
            let inputGraph = try MojoInputGraph(
                bindingGraph: MojoSourceGraph(
                    sourceURLs: [sourceURL],
                    sourceRootURL: root
                ),
                externalPackages: []
            )
            let rendered = MojoStaticSourceRenderer().render(
                inputGraph: inputGraph,
                identity: layout.identity
            )
            let output = layout.outputDirectoryURL
            let artifact = output.appendingPathComponent(
                layout.identity.artifactName,
                isDirectory: true
            )
            let slice = artifact.appendingPathComponent(
                "macos-arm64",
                isDirectory: true
            )
            let headers = slice.appendingPathComponent(
                "Headers",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: headers,
                withIntermediateDirectories: true
            )
            let archive = slice.appendingPathComponent(
                layout.identity.libraryName
            )
            try Data("release archive".utf8).write(to: archive)
            try MojoStaticSourceRenderer().header(
                identity: layout.identity
            ).write(
                to: headers.appendingPathComponent(
                    "\(layout.identity.moduleName).h"
                ),
                atomically: true,
                encoding: .utf8
            )
            try MojoStaticSourceRenderer().moduleMap(
                identity: layout.identity
            ).write(
                to: headers.appendingPathComponent("module.modulemap"),
                atomically: true,
                encoding: .utf8
            )
            let plist = try PropertyListSerialization.data(
                fromPropertyList: [
                    "AvailableLibraries": [[
                        "LibraryIdentifier": "macos-arm64",
                        "LibraryPath": layout.identity.libraryName,
                        "HeadersPath": "Headers",
                        "SupportedArchitectures": ["arm64"],
                        "SupportedPlatform": "macos",
                    ]],
                    "CFBundlePackageType": "XFWK",
                    "XCFrameworkFormatVersion": "1.0",
                ],
                format: .xml,
                options: 0
            )
            try plist.write(to: artifact.appendingPathComponent("Info.plist"))
            let sourceMapData = try rendered.sourceMap.encode()
            let generatedSourceData = Data(rendered.source.utf8)
            sourceMapURL = output.appendingPathComponent(
                MojoStaticABI.sourceMapName
            )
            try sourceMapData.write(to: sourceMapURL)
            generatedSourceURL = output.appendingPathComponent(
                MojoStaticABI.generatedMojoSourceName
            )
            try generatedSourceData.write(to: generatedSourceURL)
            let manifest = MojoArtifactManifest(
                compilerVersion: "fixture-mojo 1.0",
                artifactIdentity: layout.identity,
                inputGraph: inputGraph,
                slices: [
                    MojoArtifactManifest.Slice(
                        target: target,
                        libraryIdentifier: "macos-arm64",
                        archiveDigest: try MojoCanonicalDigest.file(at: archive)
                    ),
                ],
                generatedSourceDigest: MojoCanonicalDigest.hex(
                    generatedSourceData
                ),
                sourceMapDigest: MojoCanonicalDigest.hex(sourceMapData),
                artifactDigest: try MojoCanonicalDigest.tree(at: artifact)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: output.appendingPathComponent(MojoStaticABI.manifestName)
            )
            configuration = try SwiftMojoConfiguration(
                targets: [
                    "Model": SwiftMojoConfiguration.Target(
                        compilerVersion: "fixture-mojo 1.0",
                        mojoPackages: [],
                        slices: [target]
                    ),
                ]
            )
            try encoder.encode(configuration).write(
                to: root.appendingPathComponent(
                    SwiftMojoConfiguration.fileName
                )
            )
        }

        func remove() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove release fixture: \(error)")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func currentArtifactPassesEveryReleaseGate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let report = try MojoReleaseVerifier().verify(
            layout: fixture.layout
        )

        #expect(report.targetName == "Model")
        #expect(report.bindingCount == 1)
        #expect(report.slices.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func changedSourceMapIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("corrupt".utf8).write(to: fixture.sourceMapURL)

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func changedGeneratedMojoSourceIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("corrupt".utf8).write(to: fixture.generatedSourceURL)

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func hiddenArtifactFileIsPartOfReleaseIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("unexpected".utf8).write(
            to: fixture.layout.outputDirectoryURL
                .appendingPathComponent(fixture.layout.identity.artifactName)
                .appendingPathComponent(".unexpected")
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func artifactSymbolicLinkIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let artifactURL = fixture.layout.outputDirectoryURL
            .appendingPathComponent(fixture.layout.identity.artifactName)
        try FileManager.default.createSymbolicLink(
            at: artifactURL.appendingPathComponent("unexpected-link"),
            withDestinationURL: fixture.root.appendingPathComponent(
                "Package.swift"
            )
        )

        #expect(throws: MojoCanonicalDigestError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func symbolicLinkManifestIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fileManager = FileManager.default
        let manifestURL = fixture.layout.outputDirectoryURL
            .appendingPathComponent(MojoStaticABI.manifestName)
        let manifestTarget = fixture.root.appendingPathComponent(
            "manifest-target.json"
        )
        try fileManager.moveItem(at: manifestURL, to: manifestTarget)
        try fileManager.createSymbolicLink(
            at: manifestURL,
            withDestinationURL: manifestTarget
        )

        #expect(throws: MojoArtifactError.symbolicLinkUnsupported(
            manifestURL.path
        )) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func localPackageDependencyIsRejected() throws {
        let fixture = try Fixture(localDependency: true)
        defer { fixture.remove() }

        #expect(throws: MojoArtifactError.localPackageDependencyInRelease) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func localFileURLPackageDependencyIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            packageDependencies: "[.package(url: \"file:///tmp/Local\", branch: \"main\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.localPackageDependencyInRelease) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nonLiteralPackageURLIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try """
        // swift-tools-version: 6.2
        import PackageDescription
        let dependencyURL = "https://example.com/Dependency.git"
        let package = Package(
            name: "Fixture",
            dependencies: [.package(url: dependencyURL, branch: "main")],
            targets: [
                .binaryTarget(
                    name: "SwiftMojo_Model_ABI",
                    path: "Generated/Model/SwiftMojo_Model_ABI.xcframework"
                ),
                .target(
                    name: "Model",
                    dependencies: ["SwiftMojo_Model_ABI"],
                    plugins: [.plugin(name: "MojoBuildPlugin")]
                ),
            ]
        )
        """.write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.localPackageDependencyInRelease) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func nonRemoteLiteralPackageURLIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            packageDependencies: "[.package(url: \"../Local\", branch: \"main\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.localPackageDependencyInRelease) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func movingBranchPackageDependencyIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            packageDependencies: "[.package(url: \"https://example.com/Dependency.git\", branch: \"main\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.mutablePackageDependencyInRelease(
            "main"
        )) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func immutableRemoteRevisionIsAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            packageDependencies: "[.package(name: \"swift-mojo\", url: \"https://example.com/Dependency.git\", revision: \"candidate-revision\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MojoReleaseVerifier().verify(layout: fixture.layout)

        #expect(report.targetName == "Model")
    }

    @Test(.timeLimit(.minutes(1)))
    func exactSemanticVersionIsAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            packageDependencies: "[.package(url: \"https://example.com/swift-mojo.git\", exact: \"1.2.3\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        let report = try MojoReleaseVerifier().verify(layout: fixture.layout)

        #expect(report.targetName == "Model")
    }

    @Test(.timeLimit(.minutes(1)))
    func missingBinaryTargetIntegrationIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "Fixture",
            targets: [
                .target(
                    name: "Model",
                    dependencies: [],
                    plugins: [.plugin(name: "MojoBuildPlugin")]
                ),
            ]
        )
        """.write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func unusedManifestCallsDoNotSatisfyReleaseIntegration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try """
        // swift-tools-version: 6.2
        import PackageDescription
        func unusedTargets() -> [Target] {
            [
                .binaryTarget(
                    name: "SwiftMojo_Model_ABI",
                    path: "Generated/Model/SwiftMojo_Model_ABI.xcframework"
                ),
                .target(
                    name: "Model",
                    dependencies: ["SwiftMojo_Model_ABI"],
                    plugins: [.plugin(name: "MojoBuildPlugin")]
                ),
            ]
        }
        let package = Package(name: "Fixture", targets: [])
        """.write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func computedTargetArrayFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try """
        // swift-tools-version: 6.2
        import PackageDescription
        let targets: [Target] = [
            .binaryTarget(
                name: "SwiftMojo_Model_ABI",
                path: "Generated/Model/SwiftMojo_Model_ABI.xcframework"
            ),
            .target(
                name: "Model",
                dependencies: ["SwiftMojo_Model_ABI"],
                plugins: [.plugin(name: "MojoBuildPlugin")]
            ),
        ]
        let package = Package(name: "Fixture", targets: targets)
        """.write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func missingTargetDependencyIntegrationIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            dependencies: "[]",
            plugins: "[.plugin(name: \"MojoBuildPlugin\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func missingMojoProductDependencyIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            dependencies: "[\"SwiftMojo_Model_ABI\"]",
            plugins: "[.plugin(name: \"MojoBuildPlugin\", package: \"swift-mojo\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func pluginFromDifferentPackageIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            dependencies: "[.product(name: \"Mojo\", package: \"swift-mojo\"), \"SwiftMojo_Model_ABI\"]",
            plugins: "[.plugin(name: \"MojoBuildPlugin\", package: \"another-package\")]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func missingBuildPluginIntegrationIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try packageManifest(
            dependencies: """
            [
                .product(name: "Mojo", package: "swift-mojo"),
                "SwiftMojo_Model_ABI",
            ]
            """,
            plugins: "[]"
        ).write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(
                layout: fixture.layout
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedPackageManifestIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try "let package = Package(name: \"Fixture\"".write(
            to: fixture.root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoReleaseVerifier().verify(layout: fixture.layout)
        }
    }

    private func packageManifest(
        packageDependencies: String = "[.package(url: \"https://github.com/1amageek/swift-mojo.git\", revision: \"candidate-revision\")]",
        dependencies: String,
        plugins: String
    ) -> String {
        """
        // swift-tools-version: 6.2
        import PackageDescription
        let package = Package(
            name: "Fixture",
            dependencies: \(packageDependencies),
            targets: [
                .binaryTarget(
                    name: "SwiftMojo_Model_ABI",
                    path: "Generated/Model/SwiftMojo_Model_ABI.xcframework"
                ),
                .target(
                    name: "Model",
                    dependencies: \(dependencies),
                    plugins: \(plugins)
                ),
            ]
        )
        """
    }

    private func packageManifest(
        packageDependencies: String
    ) -> String {
        packageManifest(
            packageDependencies: packageDependencies,
            dependencies: "[.product(name: \"Mojo\", package: \"swift-mojo\"), \"SwiftMojo_Model_ABI\"]",
            plugins: "[.plugin(name: \"MojoBuildPlugin\", package: \"swift-mojo\")]"
        )
    }
}
