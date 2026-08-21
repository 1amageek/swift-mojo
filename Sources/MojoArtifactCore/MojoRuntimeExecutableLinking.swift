import Foundation
import MojoCompilerCore

package protocol MojoRuntimeExecutableLinking: Sendable {
    func link(
        objectURL: URL,
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String]
    ) throws
}
