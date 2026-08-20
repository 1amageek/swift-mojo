import Foundation

package enum MojoArtifactError: Error, Equatable, CustomStringConvertible {
    case artifactArchiveCount(Int)
    case artifactDigestMismatch(expected: String, actual: String)
    case artifactMissing(String)
    case bindingGraphMismatch
    case commandFailed(command: String, status: Int32, diagnostic: String)
    case generationPipelineMismatch(expected: String, actual: String)
    case invalidArguments(String)
    case invalidManagedOutputDirectory(String)
    case invalidManifest(String)
    case manifestMissing(String)
    case outputLockFailed(path: String, diagnostic: String)
    case outputLockScopeMismatch(expected: String, actual: String)
    case outputPathsMustShareDirectory
    case sourceGraphMismatch(expected: String, actual: String)
    case targetMismatch(
        expectedTriple: String,
        expectedCPU: String,
        actualTriple: String,
        actualCPU: String
    )
    case unmanagedOutputDirectory(String)
    case unsupportedTarget(String)

    package var description: String {
        switch self {
        case .artifactArchiveCount(let count):
            "Expected exactly one \(MojoStaticABI.libraryName) in the XCFramework; found \(count)"
        case .artifactDigestMismatch(let expected, let actual):
            "Prepared Mojo artifact digest is stale or corrupt; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .artifactMissing(let path):
            "Prepared Mojo artifact is missing at '\(path)'. Run 'swift-mojo init' and then 'swift-mojo prepare'."
        case .bindingGraphMismatch:
            "Prepared Mojo binding records do not match the current Swift sources. Run 'swift-mojo prepare'."
        case .commandFailed(let command, let status, let diagnostic):
            "Command failed with status \(status): \(command)\(diagnostic.isEmpty ? "" : "\n\(diagnostic)")"
        case .generationPipelineMismatch(let expected, let actual):
            "Prepared Mojo generation pipeline is stale; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .invalidArguments(let message):
            message
        case .invalidManagedOutputDirectory(let path):
            "The managed output directory '\(path)' is incomplete. Move it aside and run 'swift-mojo init' again."
        case .invalidManifest(let message):
            "Mojo artifact manifest is invalid: \(message)"
        case .manifestMissing(let path):
            "Prepared Mojo manifest is missing at '\(path)'. Run 'swift-mojo prepare'."
        case .outputLockFailed(let path, let diagnostic):
            "Failed to lock Mojo output at '\(path)': \(diagnostic)"
        case .outputLockScopeMismatch(let expected, let actual):
            "Mojo output lock for '\(expected)' cannot commit output at '\(actual)'"
        case .outputPathsMustShareDirectory:
            "The Mojo artifact and manifest must be managed in one generated output directory"
        case .sourceGraphMismatch(let expected, let actual):
            "Prepared Mojo sources are stale; manifest digest is \(expected), current digest is \(actual). Run 'swift-mojo prepare'."
        case .targetMismatch(
            let expectedTriple,
            let expectedCPU,
            let actualTriple,
            let actualCPU
        ):
            "Prepared Mojo target \(expectedTriple)/\(expectedCPU) does not match the Swift destination \(actualTriple)/\(actualCPU). Run 'swift-mojo prepare' for the active destination."
        case .unmanagedOutputDirectory(let path):
            "Refusing to replace unmanaged output directory '\(path)'; choose an empty path or run 'swift-mojo init' first"
        case .unsupportedTarget(let target):
            "The P1 static Mojo artifact supports only arm64 macOS; received '\(target)'"
        }
    }
}
