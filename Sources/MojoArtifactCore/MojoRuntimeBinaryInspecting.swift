import Foundation
import MojoCompilerCore

package protocol MojoRuntimeBinaryInspecting: Sendable {
    func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws

    func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection
}
