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
            "object-linkage-policy=\(MojoObjectLinkageInspector.policyVersion)",
            "registry-renderer=\(MojoStaticRegistryWriter.generationVersion)",
        ].joined(separator: "|")
    )

    package static func digest(for inputGraph: MojoInputGraph) -> String {
        let signatures = Set(
            inputGraph.bindingGraph.bindings.map(\.signature)
        )
        let hasBorrowedBuffer = signatures.contains(.borrowedFloat32Buffer)
        let hasMutableBuffers = signatures.contains(
            .borrowedMutableFloat32Buffers
        )
        let hasRuntimeSession = signatures.contains(.runtimeSessionFactory)
            || signatures.contains(.sessionFloat32BufferFactory)
            || signatures.contains(.sessionBorrowedMutableFloat32Buffers)
        let hasSessionResource = signatures.contains(
            .sessionFloat32BufferFactory
        )
        guard hasBorrowedBuffer || hasMutableBuffers || hasRuntimeSession else {
            return digest
        }
        var components = [
            "swift-mojo-signature-family-pipeline-v1",
            "base=\(digest)",
        ]
        if hasBorrowedBuffer {
            components.append(contentsOf: [
                "borrowed-float32-buffer-source=\(MojoStaticSourceRenderer.borrowedFloat32BufferGenerationVersion)",
                "borrowed-float32-buffer-registry=\(MojoStaticRegistryWriter.borrowedFloat32BufferGenerationVersion)",
                "borrowed-float32-buffer-c-abi=1",
            ])
        }
        if hasMutableBuffers {
            components.append(contentsOf: [
                "borrowed-mutable-float32-buffers-source=\(MojoStaticSourceRenderer.borrowedMutableFloat32BuffersGenerationVersion)",
                "borrowed-mutable-float32-buffers-registry=\(MojoStaticRegistryWriter.borrowedMutableFloat32BuffersGenerationVersion)",
                "borrowed-mutable-float32-buffers-c-abi=1",
            ])
        }
        if hasRuntimeSession {
            components.append(contentsOf: [
                "runtime-session-source=\(MojoStaticSourceRenderer.runtimeSessionGenerationVersion)",
                "runtime-session-registry=\(MojoStaticRegistryWriter.runtimeSessionGenerationVersion)",
                "runtime-session-c-abi=1",
            ])
        }
        if hasSessionResource {
            components.append(contentsOf: [
                "session-resource-source=\(MojoStaticSourceRenderer.sessionResourceGenerationVersion)",
                "session-resource-registry=\(MojoStaticRegistryWriter.sessionResourceGenerationVersion)",
                "session-resource-c-abi=1",
            ])
        }
        return MojoCanonicalDigest.hex(components.joined(separator: "|"))
    }
}
