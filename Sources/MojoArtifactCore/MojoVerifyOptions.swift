import Foundation
import MojoCompilerCore

package struct MojoVerifyOptions: Equatable, Sendable {
    package let sourceURLs: [URL]
    package let outputDirectoryURL: URL
    package let generatedSourceURL: URL
    package let target: MojoTargetConfiguration

    package init(
        sourceURLs: [URL],
        outputDirectoryURL: URL,
        generatedSourceURL: URL,
        targetTriple: String,
        targetCPU: String
    ) throws {
        guard !sourceURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one --source path is required"
            )
        }
        self.sourceURLs = sourceURLs
        self.outputDirectoryURL = outputDirectoryURL.standardizedFileURL
        self.generatedSourceURL = generatedSourceURL.standardizedFileURL
        self.target = try MojoTargetConfiguration(
            triple: targetTriple,
            cpu: targetCPU
        )
    }

    package var artifactURL: URL {
        outputDirectoryURL.appendingPathComponent(
            MojoStaticABI.artifactName,
            isDirectory: true
        )
    }

    package var manifestURL: URL {
        outputDirectoryURL.appendingPathComponent(MojoStaticABI.manifestName)
    }
}
