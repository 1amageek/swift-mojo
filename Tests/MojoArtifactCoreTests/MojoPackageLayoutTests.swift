import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("SwiftPM package layout")
struct MojoPackageLayoutTests {
    @Test(.timeLimit(.minutes(1)))
    func normalizedTargetNamesHaveDistinctArtifactIdentities() throws {
        let hyphenated = try MojoArtifactIdentity(targetName: "Model-Core")
        let underscored = try MojoArtifactIdentity(targetName: "Model_Core")

        #expect(hyphenated.moduleName != underscored.moduleName)
        #expect(hyphenated.artifactName != underscored.artifactName)
        #expect(hyphenated.symbolPrefix != underscored.symbolPrefix)
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptsCustomSwiftPMSourceLayoutWithoutAssumingSourcesTarget() throws {
        try withPackageFixture { root in
            let customSourceRoot = root.appendingPathComponent(
                "Implementation/API",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: customSourceRoot,
                withIntermediateDirectories: true
            )
            try "func customSource() {}".write(
                to: customSourceRoot.appendingPathComponent("API.swift"),
                atomically: true,
                encoding: .utf8
            )

            let layout = try MojoPackageLayout(
                packageRootURL: root,
                targetName: "Application"
            )

            try layout.validatePackageTarget()
            #expect(
                layout.binaryTargetRelativePath
                    == "Generated/Application/SwiftMojo_Application_ABI.xcframework"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingPackageManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { removeFixture(root) }
        let layout = try MojoPackageLayout(
            packageRootURL: root,
            targetName: "Application"
        )

        #expect(throws: MojoArtifactError.self) {
            try layout.validatePackageTarget()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnsafeTargetName() {
        #expect(throws: MojoArtifactError.self) {
            _ = try MojoPackageLayout(
                packageRootURL: URL(fileURLWithPath: "/tmp/package"),
                targetName: "../Application"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mixedNativeArtifactsRequireExactPlatformConditions() throws {
        try withPackageFixture { root in
            let layout = try MojoPackageLayout(
                packageRootURL: root,
                targetName: "Application"
            )
            let integrations = try layout.binaryIntegrations(
                targets: [
                    MojoTargetConfiguration(
                        triple: "arm64-apple-macosx14.0",
                        cpu: "generic"
                    ),
                    MojoTargetConfiguration(
                        triple: "aarch64-unknown-linux-gnu",
                        cpu: "generic"
                    ),
                ]
            )
            let packageSource = """
            // swift-tools-version: 6.2
            import PackageDescription

            let package = Package(
                name: "Fixture",
                dependencies: [
                    .package(
                        url: "https://github.com/1amageek/swift-mojo.git",
                        exact: "1.0.0"
                    ),
                ],
                targets: [
                    .binaryTarget(
                        name: "SwiftMojo_Application_ABI",
                        path: "Generated/Application/SwiftMojo_Application_ABI.xcframework"
                    ),
                    .binaryTarget(
                        name: "SwiftMojo_Application_ABI_Linux",
                        path: "Generated/Application/SwiftMojo_Application_ABI.artifactbundle"
                    ),
                    .target(
                        name: "Application",
                        dependencies: [
                            .product(name: "Mojo", package: "swift-mojo"),
                            .target(
                                name: "SwiftMojo_Application_ABI",
                                condition: .when(platforms: [.macOS])
                            ),
                            .target(
                                name: "SwiftMojo_Application_ABI_Linux",
                                condition: .when(platforms: [.linux])
                            ),
                        ],
                        plugins: [
                            .plugin(
                                name: "MojoBuildPlugin",
                                package: "swift-mojo"
                            ),
                        ]
                    ),
                ]
            )
            """
            let manifestURL = root.appendingPathComponent("Package.swift")
            try packageSource.write(
                to: manifestURL,
                atomically: true,
                encoding: .utf8
            )

            _ = try PackageManifestReleaseInspector
                .validateReleaseIntegration(
                    packageRootURL: root,
                    targetName: "Application",
                    binaryIntegrations: integrations
                )

            let wrongLinuxCondition = packageSource.replacingOccurrences(
                of: "condition: .when(platforms: [.linux])",
                with: "condition: .when(platforms: [.macOS])"
            )
            #expect(wrongLinuxCondition != packageSource)
            try wrongLinuxCondition.write(
                to: manifestURL,
                atomically: true,
                encoding: .utf8
            )
            #expect(throws: MojoArtifactError.self) {
                _ = try PackageManifestReleaseInspector
                    .validateReleaseIntegration(
                        packageRootURL: root,
                        targetName: "Application",
                        binaryIntegrations: integrations
                    )
            }
        }
    }

    private func withPackageFixture(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try "// swift-tools-version: 6.2".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { removeFixture(root) }
        try body(root)
    }
}

private func removeFixture(_ root: URL) {
    do {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    } catch {
        Issue.record("Failed to remove package fixture: \(error)")
    }
}
