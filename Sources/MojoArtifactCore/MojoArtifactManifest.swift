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

    package struct ExternalPackage: Codable, Equatable, Sendable {
        package let name: String
        package let digest: String

        package init(name: String, digest: String) {
            self.name = name
            self.digest = digest
        }
    }

    package struct Slice: Codable, Equatable, Sendable {
        package let target: MojoTargetConfiguration
        package let libraryIdentifier: String
        package let archiveDigest: String

        package init(
            target: MojoTargetConfiguration,
            libraryIdentifier: String,
            archiveDigest: String
        ) {
            self.target = target
            self.libraryIdentifier = libraryIdentifier
            self.archiveDigest = archiveDigest
        }
    }

    package static let currentSchemaVersion = 4
    package static let legacySchemaVersion = 3

    package let schemaVersion: Int
    package let abiVersion: UInt32
    package let compilerVersion: String
    package let generationPipelineDigest: String
    package let target: MojoTargetConfiguration?
    package let artifactIdentity: MojoArtifactIdentity?
    package let sourceGraphDigest: String
    package let sourceGraphIdentifier: UInt64
    package let inputGraphDigest: String?
    package let inputGraphIdentifier: UInt64?
    package let generatedSourceDigest: String?
    package let sourceMapDigest: String?
    package let artifactDigest: String
    package let bindings: [Binding]
    package let externalPackages: [ExternalPackage]?
    package let slices: [Slice]?

    package init(
        compilerVersion: String,
        artifactIdentity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        slices: [Slice],
        generatedSourceDigest: String,
        sourceMapDigest: String,
        artifactDigest: String,
        generationPipelineDigest: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.abiVersion = MojoStaticABI.version
        self.compilerVersion = compilerVersion
        self.generationPipelineDigest = generationPipelineDigest
            ?? MojoGenerationPipeline.digest(for: inputGraph)
        self.target = nil
        self.artifactIdentity = artifactIdentity
        self.sourceGraphDigest = inputGraph.bindingGraph.digest
        self.sourceGraphIdentifier = inputGraph.bindingGraph.digestIdentifier
        self.inputGraphDigest = inputGraph.digest
        self.inputGraphIdentifier = inputGraph.digestIdentifier
        self.generatedSourceDigest = generatedSourceDigest
        self.sourceMapDigest = sourceMapDigest
        self.artifactDigest = artifactDigest
        self.bindings = inputGraph.bindingGraph.bindings.map(Binding.init)
        self.externalPackages = inputGraph.externalPackages.map(\.manifestRecord)
        self.slices = slices.sorted {
            $0.target.identity < $1.target.identity
        }
    }

    package init(
        compilerVersion: String,
        target: MojoTargetConfiguration,
        sourceGraph: MojoSourceGraph,
        artifactDigest: String,
        generationPipelineDigest: String = MojoGenerationPipeline.legacyDigest
    ) {
        self.schemaVersion = Self.legacySchemaVersion
        self.abiVersion = MojoStaticABI.version
        self.compilerVersion = compilerVersion
        self.generationPipelineDigest = generationPipelineDigest
        self.target = target
        self.artifactIdentity = nil
        self.sourceGraphDigest = sourceGraph.digest
        self.sourceGraphIdentifier = sourceGraph.digestIdentifier
        self.inputGraphDigest = nil
        self.inputGraphIdentifier = nil
        self.generatedSourceDigest = nil
        self.sourceMapDigest = nil
        self.artifactDigest = artifactDigest
        self.bindings = sourceGraph.bindings.map(Binding.init)
        self.externalPackages = nil
        self.slices = nil
    }

    package var effectiveIdentity: MojoArtifactIdentity {
        artifactIdentity ?? .legacy
    }

    package var effectiveSlices: [Slice] {
        if let slices {
            return slices
        }
        guard let target else {
            return []
        }
        return [
            Slice(
                target: target,
                libraryIdentifier: "legacy",
                archiveDigest: "legacy"
            ),
        ]
    }
}
