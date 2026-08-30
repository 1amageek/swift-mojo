import Foundation
import MojoArtifactCore

public struct FileSystemMojoRuntimeWorkerBundleVerifier:
    MojoRuntimeWorkerBundleVerifying, Sendable
{
    private let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
    }

    public func verifyWorkerBundle(
        at bundleURL: URL
    ) throws -> MojoRuntimeWorkerBundleVerification {
        do {
            let manifest = try MojoRuntimeWorkerBundleVerifier(
                environment: environment
            ).verify(bundleURL: bundleURL)
            return try Self.verification(
                from: manifest,
                bundleURL: bundleURL
            )
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
        from manifest: MojoRuntimeWorkerBundleManifest,
        bundleURL: URL
    ) throws -> MojoRuntimeWorkerBundleVerification {
        let bindings = try manifest.semanticIdentity.bindings.map { binding in
            guard let signature = MojoRuntimeWorkerBindingSignature(
                rawValue: binding.signature.rawValue
            ) else {
                throw MojoRuntimeBundleVerificationError.invalidBundle(
                    "unsupported runtime worker binding signature '\(binding.signature.rawValue)'"
                )
            }
            return MojoRuntimeWorkerBinding(
                bindingID: binding.bindingID,
                functionName: binding.functionName,
                signature: signature,
                sessionFactoryFunctionName: binding
                    .sessionFactoryFunctionName
            )
        }
        let target = try manifest.targetClosure.target
        let bindingTable = try manifest.semanticIdentity.bindingTable
        return MojoRuntimeWorkerBundleVerification(
            schemaVersion: manifest.schemaVersion,
            bundleDigest: manifest.digest,
            executionContractDigest: manifest.executionContractDigest,
            workerABIVersion: manifest.semanticIdentity.workerABIVersion,
            sourceGraphDigest: manifest.semanticIdentity.sourceGraphDigest,
            sourceGraphIdentifier: manifest.semanticIdentity
                .sourceGraphIdentifier,
            inputGraphDigest: manifest.semanticIdentity.inputGraphDigest,
            inputGraphIdentifier: manifest.semanticIdentity
                .inputGraphIdentifier,
            generationPipelineDigest: manifest.semanticIdentity
                .generationPipelineDigest,
            bindingTableDigest: bindingTable.digest,
            bindings: bindings,
            generatedMojoSourceDigest: manifest.generatedInputs
                .generatedMojoSourceDigest,
            generatedCWorkerSourceDigest: manifest.generatedInputs
                .generatedCWorkerSourceDigest,
            sourceMapDigest: manifest.generatedInputs.sourceMapDigest,
            generatedMojoObjectDigest: manifest.generatedInputs
                .generatedMojoObjectDigest,
            generatedCWorkerObjectDigest: manifest.generatedInputs
                .generatedCWorkerObjectDigest,
            compilerVersion: manifest.generatedInputs.compilerVersion,
            protocolVersion: manifest.protocolRecord.version,
            protocolDescriptor: manifest.protocolRecord.descriptor,
            protocolHeaderByteCount: manifest.protocolRecord.headerByteCount,
            protocolByteOrder: manifest.protocolRecord.byteOrder,
            maximumFramePayloadBytes: manifest.protocolRecord
                .maximumFramePayloadBytes,
            maximumInFlightRequests: manifest.protocolRecord
                .maximumInFlightRequests,
            protocolMessageKinds: manifest.protocolRecord.messageKinds.map {
                MojoRuntimeWorkerMessageKind(
                    rawValue: $0.rawValue,
                    name: $0.name
                )
            },
            runtimeBundleManifestDigest: manifest.runtimeBundle.manifestDigest,
            runtimeReceiptDigest: manifest.runtimeBundle.receiptDigest,
            executable: MojoRuntimeBundleFile(
                relativePath: manifest.runtimeBundle.executable.relativePath,
                sha256Digest: manifest.runtimeBundle.executable.digest
            ),
            libraries: manifest.runtimeBundle.libraries.map {
                MojoRuntimeBundleFile(
                    relativePath: $0.relativePath,
                    sha256Digest: $0.digest
                )
            },
            loaderSearchPath: manifest.runtimeBundle.loaderSearchPath,
            systemDependencies: manifest.runtimeBundle.systemDependencies,
            programInterpreter: manifest.runtimeBundle.programInterpreter,
            target: MojoRuntimeBundleTarget(
                triple: target.triple,
                cpu: target.cpu,
                accelerator: target.accelerator
            ),
            artifactIdentity: MojoRuntimeWorkerArtifactIdentity(
                targetName: manifest.targetClosure.artifactIdentity.targetName,
                moduleName: manifest.targetClosure.artifactIdentity.moduleName,
                artifactName: manifest.targetClosure.artifactIdentity
                    .artifactName,
                libraryName: manifest.targetClosure.artifactIdentity
                    .libraryName,
                symbolPrefix: manifest.targetClosure.artifactIdentity
                    .symbolPrefix
            ),
            targetClosureDigest: manifest.targetClosure.targetClosureDigest,
            verifiedBundleURL: bundleURL
        )
    }
}
