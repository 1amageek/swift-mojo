import MojoBindingCore

package enum MojoGenerationPipeline {
    package static let legacyDigest = MojoCanonicalDigest.hex(
        [
            "swift-mojo-generation-pipeline-v1",
            "binding-ir=1",
            "mojo-source-renderer=1",
            "static-abi=1",
            "artifact-packaging=1",
            "registry-renderer=1",
        ].joined(separator: "|")
    )

    package static let digest = MojoCanonicalDigest.hex(
        [
            "swift-mojo-generation-pipeline-v2",
            "binding-ir=\(MojoBinding.schemaVersion)",
            "mojo-source-renderer=\(MojoStaticSourceRenderer.generationVersion)",
            "static-abi=\(MojoStaticABI.version)",
            "artifact-packaging=\(MojoArtifactPreparer.packagingVersion)",
            "registry-renderer=\(MojoStaticRegistryWriter.generationVersion)",
        ].joined(separator: "|")
    )
}
