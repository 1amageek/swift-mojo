package struct MojoPrepareResult: Equatable, Sendable {
    package enum Disposition: String, Equatable, Sendable {
        case prepared
        case reused
    }

    package let manifest: MojoArtifactManifest
    package let disposition: Disposition

    package init(
        manifest: MojoArtifactManifest,
        disposition: Disposition
    ) {
        self.manifest = manifest
        self.disposition = disposition
    }
}
