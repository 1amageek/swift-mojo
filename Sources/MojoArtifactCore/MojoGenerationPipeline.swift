import MojoBindingCore

package enum MojoGenerationPipeline {
    package static let digest = MojoCanonicalDigest.hex(
        [
            "swift-mojo-generation-pipeline-v1",
            "binding-ir=\(MojoBinding.schemaVersion)",
            "mojo-source-renderer=\(MojoStaticSourceRenderer.generationVersion)",
            "static-abi=\(MojoStaticABI.version)",
            "artifact-packaging=\(MojoArtifactPreparer.packagingVersion)",
            "registry-renderer=\(MojoStaticRegistryWriter.generationVersion)",
        ].joined(separator: "|")
    )
}
