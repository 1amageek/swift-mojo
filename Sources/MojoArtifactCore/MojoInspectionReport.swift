package struct MojoInspectionReport: Codable, Equatable, Sendable {
    package let targetName: String
    package let moduleName: String
    package let artifactName: String
    package let inputGraphDigest: String
    package let bindingCount: Int
    package let externalPackageCount: Int
    package let generatedMojo: String
    package let preparedManifest: MojoArtifactManifest?

    package init(
        targetName: String,
        identity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        generatedMojo: String,
        preparedManifest: MojoArtifactManifest?
    ) {
        self.targetName = targetName
        self.moduleName = identity.moduleName
        self.artifactName = identity.artifactName
        self.inputGraphDigest = inputGraph.digest
        self.bindingCount = inputGraph.bindingGraph.bindings.count
        self.externalPackageCount = inputGraph.externalPackages.count
        self.generatedMojo = generatedMojo
        self.preparedManifest = preparedManifest
    }
}
