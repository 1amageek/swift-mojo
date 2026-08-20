import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

@Suite("Prepared Mojo artifact verification")
struct MojoArtifactVerifierTests {
    @Test(.timeLimit(.minutes(1)))
    func validArtifactGeneratesStaticRegistry() throws {
        try withFixture { fixture in
            let generated = fixture.root.appendingPathComponent("Registry.swift")
            let options = try fixture.verifyOptions(generatedSource: generated)

            let manifest = try MojoArtifactVerifier().verify(options: options)
            let source = try String(contentsOf: generated, encoding: .utf8)

            #expect(manifest.sourceGraphDigest == fixture.graph.digest)
            #expect(source.contains("import GeneratedMojoABI"))
            #expect(source.contains("swift_mojo_has_binding"))
            #expect(source.contains(manifest.artifactDigest))
            #expect(source.contains("guard swift_mojo_static_abi_version()"))
            #expect(source.contains("fatalError("))
            #expect(!source.contains("precondition("))
            #expect(!source.contains(fixture.outputDirectory.path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func staleSourceIsRejectedBeforeRegistryGeneration() throws {
        try withFixture { fixture in
            try fixture.reversedSource.write(
                to: fixture.sourceURL,
                atomically: true,
                encoding: .utf8
            )
            let generated = fixture.root.appendingPathComponent("Registry.swift")
            do {
                _ = try MojoArtifactVerifier().verify(
                    options: fixture.verifyOptions(generatedSource: generated)
                )
                Issue.record("Stale source unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .sourceGraphMismatch = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(!FileManager.default.fileExists(atPath: generated.path))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func corruptArchiveIsRejected() throws {
        try withFixture { fixture in
            try Data("corrupt".utf8).write(to: fixture.archiveURL)
            do {
                _ = try MojoArtifactVerifier().verify(
                    options: fixture.verifyOptions(
                        generatedSource: fixture.root.appendingPathComponent(
                            "Registry.swift"
                        )
                    )
                )
                Issue.record("Corrupt archive unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .artifactDigestMismatch = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func corruptHeaderIsRejected() throws {
        try withFixture { fixture in
            try Data("corrupt header".utf8).write(to: fixture.headerURL)
            do {
                _ = try MojoArtifactVerifier().verify(
                    options: fixture.verifyOptions(
                        generatedSource: fixture.root.appendingPathComponent(
                            "Registry.swift"
                        )
                    )
                )
                Issue.record("Corrupt header unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .artifactDigestMismatch = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func wrongTargetIsRejected() throws {
        try withFixture { fixture in
            let options = try MojoVerifyOptions(
                sourceURLs: [fixture.sourceURL],
                outputDirectoryURL: fixture.outputDirectory,
                generatedSourceURL: fixture.root.appendingPathComponent(
                    "Registry.swift"
                ),
                targetTriple: "arm64-apple-macosx15.0",
                targetCPU: "generic"
            )
            do {
                _ = try MojoArtifactVerifier().verify(options: options)
                Issue.record("Wrong target unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .targetMismatch = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
            }
        }
    }

    private func withFixture(
        _ body: (ArtifactFixture) throws -> Void
    ) throws {
        let fixture = try ArtifactFixture()
        do {
            try body(fixture)
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            do {
                if FileManager.default.fileExists(atPath: fixture.root.path) {
                    try FileManager.default.removeItem(at: fixture.root)
                }
            } catch let cleanupError {
                Issue.record("Temporary fixture cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }
}

private struct ArtifactFixture {
    let root: URL
    let outputDirectory: URL
    let sourceURL: URL
    let archiveURL: URL
    let headerURL: URL
    let graph: MojoSourceGraph
    let target: MojoTargetConfiguration

    let reversedSource = """
    @mojo
    func add(_ a: Int32, _ b: Int32) -> Int32 {
        return b + a
    }
    """

    init() throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        outputDirectory = root.appendingPathComponent(
            "Generated",
            isDirectory: true
        )
        sourceURL = root.appendingPathComponent("Bindings.swift")
        archiveURL = outputDirectory
            .appendingPathComponent(
                MojoStaticABI.artifactName,
                isDirectory: true
            )
            .appendingPathComponent("macos-arm64", isDirectory: true)
            .appendingPathComponent(MojoStaticABI.libraryName)
        headerURL = outputDirectory
            .appendingPathComponent(
                MojoStaticABI.artifactName,
                isDirectory: true
            )
            .appendingPathComponent("macos-arm64/Headers", isDirectory: true)
            .appendingPathComponent("GeneratedMojoABI.h")
        try fileManager.createDirectory(
            at: headerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return a + b
        }
        """
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try Data("archive".utf8).write(to: archiveURL)
        try Data("header".utf8).write(to: headerURL)
        graph = try MojoSourceGraph(sourceURLs: [sourceURL])
        target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )
        let manifest = MojoArtifactManifest(
            compilerVersion: "test-mojo 1.0.0",
            target: target,
            sourceGraph: graph,
            artifactDigest: try MojoCanonicalDigest.tree(
                at: outputDirectory.appendingPathComponent(
                    MojoStaticABI.artifactName,
                    isDirectory: true
                )
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: outputDirectory.appendingPathComponent(
                MojoStaticABI.manifestName
            ),
            options: .atomic
        )
    }

    func verifyOptions(generatedSource: URL) throws -> MojoVerifyOptions {
        try MojoVerifyOptions(
            sourceURLs: [sourceURL],
            outputDirectoryURL: outputDirectory,
            generatedSourceURL: generatedSource,
            targetTriple: target.triple,
            targetCPU: target.cpu
        )
    }
}
