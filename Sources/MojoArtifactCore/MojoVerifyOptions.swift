import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoVerifyOptions: Equatable, Sendable {
    package let sourceURLs: [URL]
    package let sourceRootURL: URL?
    package let externalPackages: [MojoExternalPackage]
    package let outputDirectoryURL: URL
    package let generatedSourceURL: URL
    package let target: MojoTargetConfiguration?
    package let expectedIdentity: MojoArtifactIdentity?
    package let expectedCompilerVersion: String?
    package let expectedSlices: [MojoTargetConfiguration]?

    package init(
        sourceURLs: [URL],
        sourceRootURL: URL? = nil,
        externalPackages: [MojoExternalPackage] = [],
        outputDirectoryURL: URL,
        generatedSourceURL: URL,
        target: MojoTargetConfiguration? = nil,
        expectedIdentity: MojoArtifactIdentity? = nil,
        expectedCompilerVersion: String? = nil,
        expectedSlices: [MojoTargetConfiguration]? = nil
    ) throws {
        guard !sourceURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one --source path is required"
            )
        }
        self.sourceURLs = sourceURLs.sorted { $0.path < $1.path }
        self.sourceRootURL = sourceRootURL?.standardizedFileURL
        self.externalPackages = externalPackages.sorted { $0.name < $1.name }
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.generatedSourceURL = generatedSourceURL.standardizedFileURL
        self.target = target
        self.expectedIdentity = expectedIdentity
        self.expectedCompilerVersion = expectedCompilerVersion
        self.expectedSlices = expectedSlices?.sorted {
            $0.identity < $1.identity
        }
    }

    package init(
        sourceURLs: [URL],
        outputDirectoryURL: URL,
        generatedSourceURL: URL,
        targetTriple: String,
        targetCPU: String
    ) throws {
        try self.init(
            sourceURLs: sourceURLs,
            outputDirectoryURL: outputDirectoryURL,
            generatedSourceURL: generatedSourceURL,
            target: MojoTargetConfiguration(
                triple: targetTriple,
                cpu: targetCPU
            )
        )
    }

    package var manifestURL: URL {
        outputDirectoryURL.appendingPathComponent(MojoStaticABI.manifestName)
    }

    package var sourceMapURL: URL {
        outputDirectoryURL.appendingPathComponent(MojoStaticABI.sourceMapName)
    }

    package var preparedSourceURL: URL {
        outputDirectoryURL.appendingPathComponent(
            MojoStaticABI.generatedMojoSourceName
        )
    }

    package func artifactURL(identity: MojoArtifactIdentity) -> URL {
        outputDirectoryURL.appendingPathComponent(
            identity.artifactName,
            isDirectory: true
        )
    }

    package func inputGraph() throws -> MojoInputGraph {
        let currentExternalPackages = try externalPackages.map {
            try MojoExternalPackage(name: $0.name, rootURL: $0.rootURL)
        }
        return try MojoInputGraph(
            bindingGraph: MojoSourceGraph(
                sourceURLs: sourceURLs,
                sourceRootURL: sourceRootURL
            ),
            externalPackages: currentExternalPackages
        )
    }
}
