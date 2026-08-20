import MojoBindingCore
import MojoCompilerCore

package struct MojoArtifactManifest: Codable, Equatable, Sendable {
    package struct Binding: Codable, Equatable, Sendable {
        package let bindingID: UInt64
        package let functionName: String
        package let abiDigest: String
        package let implementationDigest: String

        package init(_ binding: MojoBinding) {
            self.bindingID = binding.bindingID
            self.functionName = binding.functionName
            self.abiDigest = binding.abiDigest
            self.implementationDigest = binding.implementationDigest
        }
    }

    package static let currentSchemaVersion = 3

    package let schemaVersion: Int
    package let abiVersion: UInt32
    package let compilerVersion: String
    package let generationPipelineDigest: String
    package let target: MojoTargetConfiguration
    package let sourceGraphDigest: String
    package let sourceGraphIdentifier: UInt64
    package let artifactDigest: String
    package let bindings: [Binding]

    package init(
        compilerVersion: String,
        target: MojoTargetConfiguration,
        sourceGraph: MojoSourceGraph,
        artifactDigest: String,
        generationPipelineDigest: String = MojoGenerationPipeline.digest
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.abiVersion = MojoStaticABI.version
        self.compilerVersion = compilerVersion
        self.generationPipelineDigest = generationPipelineDigest
        self.target = target
        self.sourceGraphDigest = sourceGraph.digest
        self.sourceGraphIdentifier = sourceGraph.digestIdentifier
        self.artifactDigest = artifactDigest
        self.bindings = sourceGraph.bindings.map(Binding.init)
    }
}
