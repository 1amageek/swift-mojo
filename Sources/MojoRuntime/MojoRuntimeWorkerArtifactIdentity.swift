public struct MojoRuntimeWorkerArtifactIdentity: Equatable, Sendable {
    public let targetName: String
    public let moduleName: String
    public let artifactName: String
    public let libraryName: String
    public let symbolPrefix: String

    package init(
        targetName: String,
        moduleName: String,
        artifactName: String,
        libraryName: String,
        symbolPrefix: String
    ) {
        self.targetName = targetName
        self.moduleName = moduleName
        self.artifactName = artifactName
        self.libraryName = libraryName
        self.symbolPrefix = symbolPrefix
    }
}
