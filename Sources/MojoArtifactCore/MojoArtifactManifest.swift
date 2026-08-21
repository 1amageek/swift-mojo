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

    package struct Artifact: Codable, Equatable, Sendable {
        package let adapter: MojoNativeArtifactAdapter
        package let name: String
        package let digest: String

        package init(
            adapter: MojoNativeArtifactAdapter,
            name: String,
            digest: String
        ) {
            self.adapter = adapter
            self.name = name
            self.digest = digest
        }
    }

    package static let currentSchemaVersion = 5
    package static let appleSchemaVersion = 4
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
    package let artifacts: [Artifact]?
    package let slices: [Slice]?

    package init(
        compilerVersion: String,
        artifactIdentity: MojoArtifactIdentity,
        inputGraph: MojoInputGraph,
        slices: [Slice],
        generatedSourceDigest: String,
        sourceMapDigest: String,
        artifacts: [Artifact],
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
        let sortedArtifacts = artifacts.sorted {
            $0.adapter.rawValue < $1.adapter.rawValue
        }
        self.artifactDigest = Self.digest(artifacts: sortedArtifacts)
        self.bindings = inputGraph.bindingGraph.bindings.map(Binding.init)
        self.externalPackages = inputGraph.externalPackages.map(\.manifestRecord)
        self.artifacts = sortedArtifacts
        self.slices = slices.sorted {
            $0.target.identity < $1.target.identity
        }
    }

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
        self.init(
            compilerVersion: compilerVersion,
            artifactIdentity: artifactIdentity,
            inputGraph: inputGraph,
            slices: slices,
            generatedSourceDigest: generatedSourceDigest,
            sourceMapDigest: sourceMapDigest,
            artifacts: [
                Artifact(
                    adapter: .appleXCFramework,
                    name: artifactIdentity.artifactName,
                    digest: artifactDigest
                ),
            ],
            generationPipelineDigest: generationPipelineDigest
        )
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
        self.artifacts = nil
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

    package var effectiveArtifacts: [Artifact] {
        if let artifacts {
            return artifacts
        }
        return [
            Artifact(
                adapter: .appleXCFramework,
                name: effectiveIdentity.artifactName,
                digest: artifactDigest
            ),
        ]
    }

    package var supportsInputGraph: Bool {
        schemaVersion >= Self.appleSchemaVersion
    }

    package static func digest(artifacts: [Artifact]) -> String {
        let canonical = artifacts.sorted {
            $0.adapter.rawValue < $1.adapter.rawValue
        }.map { artifact in
            [artifact.adapter.rawValue, artifact.name, artifact.digest]
                .map { "\($0.utf8.count):\($0)" }
                .joined(separator: "|")
        }.joined(separator: "\n")
        return MojoCanonicalDigest.hex(canonical)
    }
}
