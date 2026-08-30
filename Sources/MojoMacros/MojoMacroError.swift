enum MojoMacroError: Error, CustomStringConvertible {
    case artifactFileScopeRequired
    case artifactOnlyFunctions
    case invalidArtifactFunctionSignature
    case onlyFunctions

    var description: String {
        switch self {
        case .artifactFileScopeRequired:
            "@mojoStaticArtifactAttestation functions must be declared at file scope"
        case .artifactOnlyFunctions:
            "@mojoStaticArtifactAttestation can only be attached to a function"
        case .invalidArtifactFunctionSignature:
            "@mojoStaticArtifactAttestation requires a bodyless synchronous parameterless throwing function returning MojoStaticArtifactAttestation"
        case .onlyFunctions:
            "@mojo can only be attached to a function"
        }
    }
}
