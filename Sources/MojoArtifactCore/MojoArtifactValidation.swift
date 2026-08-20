package struct MojoArtifactValidation: Equatable, Sendable {
    package let manifest: MojoArtifactManifest
    package let inputGraph: MojoInputGraph

    package init(
        manifest: MojoArtifactManifest,
        inputGraph: MojoInputGraph
    ) {
        self.manifest = manifest
        self.inputGraph = inputGraph
    }
}
