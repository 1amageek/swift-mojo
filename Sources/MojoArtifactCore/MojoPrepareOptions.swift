import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoPrepareOptions: Equatable, Sendable {
    package let sourceURLs: [URL]
    package let sourceRootURL: URL?
    package let externalPackages: [MojoExternalPackage]
    package let outputDirectoryURL: URL
    package let identity: MojoArtifactIdentity
    package let targets: [MojoTargetConfiguration]
    package let expectedCompilerVersion: String?

    package init(
        sourceURLs: [URL],
        sourceRootURL: URL? = nil,
        externalPackages: [MojoExternalPackage] = [],
        outputDirectoryURL: URL,
        identity: MojoArtifactIdentity,
        targets: [MojoTargetConfiguration],
        expectedCompilerVersion: String? = nil
    ) throws {
        guard !sourceURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one --source path is required"
            )
        }
        guard !targets.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one target slice is required"
            )
        }
        guard Set(targets.map(\.identity)).count == targets.count else {
            throw MojoArtifactError.invalidArguments(
                "Target slices must be unique"
            )
        }
        let selectors = try targets.map {
            try MojoXCFrameworkSliceIdentity(target: $0)
        }
        guard Set(selectors).count == selectors.count else {
            throw MojoArtifactError.invalidArguments(
                "Target slices must have distinct XCFramework platform/architecture variants"
            )
        }
        self.sourceURLs = sourceURLs.sorted { $0.path < $1.path }
        self.sourceRootURL = sourceRootURL?.standardizedFileURL
        self.externalPackages = externalPackages.sorted { $0.name < $1.name }
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.identity = identity
        self.targets = targets.sorted { $0.identity < $1.identity }
        self.expectedCompilerVersion = expectedCompilerVersion
    }

    package init(
        sourceURLs: [URL],
        outputDirectoryURL: URL,
        targetTriple: String,
        targetCPU: String
    ) throws {
        try self.init(
            sourceURLs: sourceURLs,
            outputDirectoryURL: outputDirectoryURL,
            identity: .legacy,
            targets: [
                MojoTargetConfiguration(
                    triple: targetTriple,
                    cpu: targetCPU
                ),
            ],
            expectedCompilerVersion: nil
        )
    }

    package var artifactURL: URL {
        outputDirectoryURL.appendingPathComponent(
            identity.artifactName,
            isDirectory: true
        )
    }

    package var manifestURL: URL {
        outputDirectoryURL.appendingPathComponent(MojoStaticABI.manifestName)
    }

    package var sourceMapURL: URL {
        outputDirectoryURL.appendingPathComponent(MojoStaticABI.sourceMapName)
    }

    package var generatedSourceURL: URL {
        outputDirectoryURL.appendingPathComponent(
            MojoStaticABI.generatedMojoSourceName
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
