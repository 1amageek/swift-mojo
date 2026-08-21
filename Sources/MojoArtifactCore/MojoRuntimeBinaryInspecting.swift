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

    func inspectExecutable(
        executableURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeExecutableInspection
}
