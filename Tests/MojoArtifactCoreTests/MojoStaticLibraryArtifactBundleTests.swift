import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Mojo Linux static-library artifact bundle")
struct MojoStaticLibraryArtifactBundleTests {
    @Test(.timeLimit(.minutes(1)))
    func createsAndValidatesSE0482Layout() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }

        let slices = try MojoStaticLibraryArtifactBundleLayout.create(
            at: fixture.artifactURL,
            identity: fixture.identity,
            archives: [
                (
                    target: fixture.target,
                    archiveURL: fixture.archiveURL
                ),
            ],
            header: "#include <stdint.h>\n",
            moduleMap: MojoStaticSourceRenderer().moduleMap(
                identity: fixture.identity
            )
        )

        #expect(slices.count == 1)
        #expect(slices[0].target == fixture.target)
        let info = try JSONDecoder().decode(
            MojoStaticLibraryArtifactBundleLayout.Info.self,
            from: Data(
                contentsOf: fixture.artifactURL.appendingPathComponent(
                    "info.json"
                )
            )
        )
        let artifact = try #require(
            info.artifacts[fixture.identity.linuxBinaryTargetName]
        )
        #expect(info.schemaVersion == "1.0")
        #expect(artifact.type == "staticLibrary")
        #expect(artifact.variants.count == 1)
        #expect(
            artifact.variants[0].supportedTriples
                == ["aarch64-unknown-linux-gnu"]
        )
        #expect(
            artifact.variants[0].staticLibraryMetadata.headerPaths
                == ["include"]
        )
        #expect(
            artifact.variants[0].staticLibraryMetadata.moduleMapPath
                == "include/module.modulemap"
        )
        try MojoStaticLibraryArtifactBundleLayout.validate(
            artifactURL: fixture.artifactURL,
            identity: fixture.identity,
            slices: slices
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMetadataThatRedirectsTheArchivePath() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanup() }
        let slices = try MojoStaticLibraryArtifactBundleLayout.create(
            at: fixture.artifactURL,
            identity: fixture.identity,
            archives: [
                (
                    target: fixture.target,
                    archiveURL: fixture.archiveURL
                ),
            ],
            header: "#include <stdint.h>\n",
            moduleMap: MojoStaticSourceRenderer().moduleMap(
                identity: fixture.identity
            )
        )
        let infoURL = fixture.artifactURL.appendingPathComponent("info.json")
        let original = try String(contentsOf: infoURL, encoding: .utf8)
        let corrupted = original.replacingOccurrences(
            of: "variants\\/",
            with: "..\\/outside\\/"
        )
        #expect(corrupted != original)
        try corrupted.write(to: infoURL, atomically: true, encoding: .utf8)

        #expect(
            throws: MojoArtifactError.self
        ) {
            try MojoStaticLibraryArtifactBundleLayout.validate(
                artifactURL: fixture.artifactURL,
                identity: fixture.identity,
                slices: slices
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsLinuxSlicesWithTheSameSwiftPMSelector() throws {
        let first = try MojoTargetConfiguration(
            triple: "aarch64-unknown-linux-gnu",
            cpu: "generic"
        )
        let second = try MojoTargetConfiguration(
            triple: "aarch64-unknown-linux-gnu",
            cpu: "apple-m1"
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoNativeArtifactAdapter.validate(
                targets: [first, second],
                error: MojoArtifactError.invalidArguments
            )
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let archiveURL = root.appendingPathComponent("libFixture.a")
        try Data("ELF archive fixture".utf8).write(to: archiveURL)
        return Fixture(
            root: root,
            artifactURL: root.appendingPathComponent(
                "Fixture.artifactbundle",
                isDirectory: true
            ),
            archiveURL: archiveURL,
            identity: try MojoArtifactIdentity(targetName: "LinuxFixture"),
            target: try MojoTargetConfiguration(
                triple: "aarch64-unknown-linux-gnu",
                cpu: "generic"
            )
        )
    }

    private struct Fixture {
        let root: URL
        let artifactURL: URL
        let archiveURL: URL
        let identity: MojoArtifactIdentity
        let target: MojoTargetConfiguration

        func cleanup() {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove artifact fixture: \(error)")
            }
        }
    }
}
