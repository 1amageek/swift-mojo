import Foundation
import MojoBindingCore

package struct MojoArtifactVerifier: Sendable {
    private let generationPipelineDigest: String
    private let registryWriter: MojoStaticRegistryWriter

    package init(
        generationPipelineDigest: String = MojoGenerationPipeline.digest,
        registryWriter: MojoStaticRegistryWriter = MojoStaticRegistryWriter()
    ) {
        self.generationPipelineDigest = generationPipelineDigest
        self.registryWriter = registryWriter
    }

    @discardableResult
    package func verify(options: MojoVerifyOptions) throws -> MojoArtifactManifest {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.manifestURL.path) else {
            throw MojoArtifactError.manifestMissing(options.manifestURL.path)
        }
        guard fileManager.fileExists(atPath: options.artifactURL.path) else {
            throw MojoArtifactError.artifactMissing(options.artifactURL.path)
        }

        let manifest: MojoArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                MojoArtifactManifest.self,
                from: Data(contentsOf: options.manifestURL)
            )
        } catch {
            throw MojoArtifactError.invalidManifest(String(describing: error))
        }
        guard manifest.schemaVersion == MojoArtifactManifest.currentSchemaVersion else {
            throw MojoArtifactError.invalidManifest(
                "unsupported schema version \(manifest.schemaVersion)"
            )
        }
        guard manifest.abiVersion == MojoStaticABI.version else {
            throw MojoArtifactError.invalidManifest(
                "unsupported ABI version \(manifest.abiVersion)"
            )
        }
        guard manifest.generationPipelineDigest == generationPipelineDigest else {
            throw MojoArtifactError.generationPipelineMismatch(
                expected: generationPipelineDigest,
                actual: manifest.generationPipelineDigest
            )
        }
        guard manifest.target == options.target else {
            throw MojoArtifactError.targetMismatch(
                expectedTriple: manifest.target.triple,
                expectedCPU: manifest.target.cpu,
                actualTriple: options.target.triple,
                actualCPU: options.target.cpu
            )
        }

        let graph = try MojoSourceGraph(sourceURLs: options.sourceURLs)
        guard manifest.sourceGraphDigest == graph.digest,
              manifest.sourceGraphIdentifier == graph.digestIdentifier else {
            throw MojoArtifactError.sourceGraphMismatch(
                expected: manifest.sourceGraphDigest,
                actual: graph.digest
            )
        }
        guard manifest.bindings == graph.bindings.map(MojoArtifactManifest.Binding.init) else {
            throw MojoArtifactError.bindingGraphMismatch
        }

        let archives = try Self.archiveURLs(in: options.artifactURL)
        guard archives.count == 1 else {
            throw MojoArtifactError.artifactArchiveCount(archives.count)
        }
        let digest = try MojoCanonicalDigest.tree(at: options.artifactURL)
        guard digest == manifest.artifactDigest else {
            throw MojoArtifactError.artifactDigestMismatch(
                expected: manifest.artifactDigest,
                actual: digest
            )
        }

        try fileManager.createDirectory(
            at: options.generatedSourceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try registryWriter.source(manifest: manifest, graph: graph).write(
            to: options.generatedSourceURL,
            atomically: true,
            encoding: .utf8
        )
        return manifest
    }

    package static func archiveURLs(in artifactURL: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: artifactURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == MojoStaticABI.libraryName {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
