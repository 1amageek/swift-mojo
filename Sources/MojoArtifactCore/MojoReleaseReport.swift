package struct MojoReleaseReport: Codable, Equatable, Sendable {
    package let targetName: String
    package let moduleName: String
    package let compilerVersion: String
    package let inputGraphDigest: String
    package let artifactDigest: String
    package let bindingCount: Int
    package let externalPackages: [MojoArtifactManifest.ExternalPackage]
    package let slices: [MojoArtifactManifest.Slice]

    package init(
        targetName: String,
        manifest: MojoArtifactManifest
    ) {
        self.targetName = targetName
        self.moduleName = manifest.effectiveIdentity.moduleName
        self.compilerVersion = manifest.compilerVersion
        self.inputGraphDigest = manifest.inputGraphDigest ?? ""
        self.artifactDigest = manifest.artifactDigest
        self.bindingCount = manifest.bindings.count
        self.externalPackages = manifest.externalPackages ?? []
        self.slices = manifest.effectiveSlices
    }
}
