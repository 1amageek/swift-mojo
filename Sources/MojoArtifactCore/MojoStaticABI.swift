package enum MojoStaticABI {
    // Version 1 permits additive signature-family dispatchers while the three
    // identity and membership symbols keep their established meaning.
    package static let version: UInt32 = 1
    package static let legacyModuleName = "GeneratedMojoABI"
    package static let legacyArtifactName = "GeneratedMojoABI.xcframework"
    package static let manifestName = "MojoArtifact.json"
    package static let generatedMojoSourceName = "Bindings.mojo"
    package static let sourceMapName = "MojoSourceMap.json"
    package static let generatedSourceName = "SwiftMojoBindings.generated.swift"
    package static let legacyLibraryName = "libGeneratedMojoABI.a"
    package static let moduleName = legacyModuleName
    package static let artifactName = legacyArtifactName
    package static let libraryName = legacyLibraryName
}
