import Foundation
import MojoArtifactCore

public struct FileSystemMojoRuntimeBundleVerifier:
    MojoRuntimeBundleVerifying, Sendable
{
    private let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
    }

    public func verifyBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeBundleVerification {
        do {
            let manifest = try MojoArtifactCore.MojoRuntimeBundleVerifier(
                environment: environment
            ).verify(bundleURL: bundleURL)
            return Self.verification(from: manifest)
        } catch let error as MojoArtifactError {
            throw Self.publicError(from: error)
        } catch {
            throw MojoRuntimeBundleVerificationError.inspectionFailed(
                String(describing: error)
            )
        }
    }

    package static func verification(
        from manifest: MojoRuntimeBundleManifest
    ) -> MojoRuntimeBundleVerification {
        MojoRuntimeBundleVerification(
            schemaVersion: manifest.schemaVersion,
            bundleDigest: manifest.digest,
            receiptDigest: manifest.receiptDigest,
            target: MojoRuntimeBundleTarget(
                triple: manifest.target.triple,
                cpu: manifest.target.cpu,
                accelerator: manifest.target.accelerator
            ),
            loaderSearchPath: manifest.loaderSearchPath,
            programInterpreter: manifest.programInterpreter,
            executable: MojoRuntimeBundleFile(
                relativePath: manifest.executable.relativePath,
                sha256Digest: manifest.executable.digest
            ),
            libraries: manifest.libraries.map {
                MojoRuntimeBundleFile(
                    relativePath: $0.relativePath,
                    sha256Digest: $0.digest
                )
            },
            systemDependencies: manifest.systemDependencies
        )
    }

    private static func publicError(
        from error: MojoArtifactError
    ) -> MojoRuntimeBundleVerificationError {
        switch error {
        case .unsupportedTarget(let target):
            .unsupportedTarget(target)
        case .commandFailed:
            .inspectionFailed(error.description)
        default:
            .invalidBundle(error.description)
        }
    }
}
