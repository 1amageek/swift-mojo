import Foundation
import MojoCompilerCore

package protocol MojoRuntimeLibraryLinking: Sendable {
    func link(
        objectURL: URL,
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String],
        exportedSymbols: Set<String>
    ) throws
}
