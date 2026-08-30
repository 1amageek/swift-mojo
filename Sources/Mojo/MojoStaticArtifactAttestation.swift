public struct MojoStaticArtifactAttestation: Equatable, Sendable {
    public enum NativeArtifactAdapter: String, Equatable, Sendable {
        case appleXCFramework
        case linuxStaticLibraryBundle
    }

    public struct Binding: Equatable, Sendable {
        public let bindingID: UInt64
        public let functionName: String
        public let abiDigest: String
        public let implementationDigest: String

        @_spi(SwiftMojoGenerated)
        public init(
            bindingID: UInt64,
            functionName: String,
            abiDigest: String,
            implementationDigest: String
        ) {
            self.bindingID = bindingID
            self.functionName = functionName
            self.abiDigest = abiDigest
            self.implementationDigest = implementationDigest
        }
    }

    public let schemaVersion: Int
    public let abiVersion: UInt32
    public let compilerVersion: String
    public let generationPipelineDigest: String
    public let targetName: String
    public let moduleName: String
    public let sourceGraphDigest: String
    public let sourceGraphIdentifier: UInt64
    public let inputGraphDigest: String
    public let inputGraphIdentifier: UInt64
    public let generatedSourceDigest: String
    public let sourceMapDigest: String
    public let artifactSetDigest: String
    public let nativeArtifactAdapter: NativeArtifactAdapter
    public let nativeArtifactName: String
    public let nativeArtifactDigest: String
    public let targetTriple: String
    public let targetCPU: String
    public let targetAccelerator: String?
    public let libraryIdentifier: String
    public let archiveDigest: String
    public let bindings: [Binding]

    @_spi(SwiftMojoGenerated)
    public init(
        schemaVersion: Int,
        abiVersion: UInt32,
        compilerVersion: String,
        generationPipelineDigest: String,
        targetName: String,
        moduleName: String,
        sourceGraphDigest: String,
        sourceGraphIdentifier: UInt64,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        generatedSourceDigest: String,
        sourceMapDigest: String,
        artifactSetDigest: String,
        nativeArtifactAdapter: NativeArtifactAdapter,
        nativeArtifactName: String,
        nativeArtifactDigest: String,
        targetTriple: String,
        targetCPU: String,
        targetAccelerator: String?,
        libraryIdentifier: String,
        archiveDigest: String,
        bindings: [Binding]
    ) {
        self.schemaVersion = schemaVersion
        self.abiVersion = abiVersion
        self.compilerVersion = compilerVersion
        self.generationPipelineDigest = generationPipelineDigest
        self.targetName = targetName
        self.moduleName = moduleName
        self.sourceGraphDigest = sourceGraphDigest
        self.sourceGraphIdentifier = sourceGraphIdentifier
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.generatedSourceDigest = generatedSourceDigest
        self.sourceMapDigest = sourceMapDigest
        self.artifactSetDigest = artifactSetDigest
        self.nativeArtifactAdapter = nativeArtifactAdapter
        self.nativeArtifactName = nativeArtifactName
        self.nativeArtifactDigest = nativeArtifactDigest
        self.targetTriple = targetTriple
        self.targetCPU = targetCPU
        self.targetAccelerator = targetAccelerator
        self.libraryIdentifier = libraryIdentifier
        self.archiveDigest = archiveDigest
        self.bindings = bindings
    }
}
