import Foundation
import MojoArtifactCore

public struct FileSystemMojoRuntimeLibraryBundleVerifier:
    MojoRuntimeLibraryBundleVerifying, Sendable
{
    private let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
    }

    public func verifyLibraryBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeLibraryBundleVerification {
        do {
            let manifest = try MojoRuntimeLibraryBundleVerifier(
                environment: environment
            ).verify(bundleURL: bundleURL)
            return try Self.verification(from: manifest)
        } catch let error as MojoArtifactError {
            throw MojoRuntimeBundleVerificationError.fromArtifactError(error)
        } catch let error as MojoRuntimeBundleVerificationError {
            throw error
        } catch {
            throw MojoRuntimeBundleVerificationError.inspectionFailed(
                String(describing: error)
            )
        }
    }

    package static func verification(
        from manifest: MojoRuntimeLibraryBundleManifest
    ) throws -> MojoRuntimeLibraryBundleVerification {
        let bindings = try manifest.bindings.map { binding in
            guard let signature = MojoRuntimeLibraryBindingSignature(
                rawValue: binding.signature
            ) else {
                throw MojoRuntimeBundleVerificationError.invalidBundle(
                    "unsupported runtime library binding signature '\(binding.signature)'"
                )
            }
            return MojoRuntimeLibraryBinding(
                bindingID: binding.bindingID,
                functionName: binding.functionName,
                signature: signature,
                sessionFactoryFunctionName: binding
                    .sessionFactoryFunctionName
            )
        }
        return MojoRuntimeLibraryBundleVerification(
            schemaVersion: manifest.schemaVersion,
            bundleDigest: manifest.digest,
            receiptDigest: manifest.receiptDigest,
            target: MojoRuntimeBundleTarget(
                triple: manifest.target.triple,
                cpu: manifest.target.cpu,
                accelerator: manifest.target.accelerator
            ),
            moduleName: manifest.moduleName,
            compilerVersion: manifest.compilerVersion,
            inputGraphDigest: manifest.inputGraphDigest,
            inputGraphIdentifier: manifest.inputGraphIdentifier,
            generatedSourceDigest: manifest.generatedSourceDigest,
            sourceMapDigest: manifest.sourceMapDigest,
            bindings: bindings,
            loaderSearchPath: manifest.loaderSearchPath,
            library: MojoRuntimeBundleFile(
                relativePath: manifest.library.relativePath,
                sha256Digest: manifest.library.digest
            ),
            runtimeLibraries: manifest.runtimeLibraries.map {
                MojoRuntimeBundleFile(
                    relativePath: $0.relativePath,
                    sha256Digest: $0.digest
                )
            },
            interfaceHeader: MojoRuntimeBundleFile(
                relativePath: manifest.interfaceHeader.relativePath,
                sha256Digest: manifest.interfaceHeader.digest
            ),
            moduleMap: MojoRuntimeBundleFile(
                relativePath: manifest.moduleMap.relativePath,
                sha256Digest: manifest.moduleMap.digest
            ),
            exportedSymbols: manifest.exportedSymbols,
            systemDependencies: manifest.systemDependencies
        )
    }
}
