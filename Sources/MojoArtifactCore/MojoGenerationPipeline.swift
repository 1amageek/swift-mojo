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

    package static func digest(for inputGraph: MojoInputGraph) -> String {
        let signatures = Set(
            inputGraph.bindingGraph.bindings.map(\.signature)
        )
        guard signatures.contains(.borrowedFloat32Buffer) else {
            return digest
        }
        return MojoCanonicalDigest.hex(
            [
                "swift-mojo-signature-family-pipeline-v1",
                "base=\(digest)",
                "borrowed-float32-buffer-source=\(MojoStaticSourceRenderer.borrowedFloat32BufferGenerationVersion)",
                "borrowed-float32-buffer-registry=\(MojoStaticRegistryWriter.borrowedFloat32BufferGenerationVersion)",
                "borrowed-float32-buffer-c-abi=1",
            ].joined(separator: "|")
        )
    }
}
