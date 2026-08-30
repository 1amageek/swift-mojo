package enum MojoStaticArtifactAuthoring {
    package static var isSupportedHost: Bool {
#if os(macOS)
        true
#else
        false
#endif
    }

    package static func requireSupportedHost() throws {
        guard isSupportedHost else {
            throw MojoArtifactError.invalidArguments(
                "Static Mojo artifact authoring requires macOS; Linux is a prepared-artifact consumer platform"
            )
        }
    }
}
