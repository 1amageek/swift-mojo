import Foundation
import MojoRuntime
import Testing

@Suite("Mojo runtime worker verification semantics")
struct MojoRuntimeWorkerBundleVerificationSemanticsTests {
    @Test(.timeLimit(.minutes(1)))
    func ignoresOnlyTheVerifiedBundleLocation() {
        let original = workerVerificationFixture(
            at: URL(fileURLWithPath: "/private/original.bundle")
        )
        let relocated = workerVerificationFixture(
            at: URL(fileURLWithPath: "/private/staged.bundle")
        )

        #expect(original != relocated)
        #expect(original.hasSameRuntimeSemantics(as: relocated))
        #expect(relocated.hasSameRuntimeSemantics(as: original))
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsEveryChangedPublicField() {
        let original = workerVerificationFixture(
            at: URL(fileURLWithPath: "/private/original.bundle")
        )

        for field in WorkerVerificationSemanticField.allCases {
            let changed = original.changingSemanticField(field)
            #expect(
                !original.hasSameRuntimeSemantics(as: changed),
                "Accepted changed semantic field: \(field.rawValue)"
            )
            #expect(
                !changed.hasSameRuntimeSemantics(as: original),
                "Semantic comparison was asymmetric for: \(field.rawValue)"
            )
        }
    }
}

private enum WorkerVerificationSemanticField: String, CaseIterable {
    case schemaVersion
    case bundleDigest
    case executionContractDigest
    case workerABIVersion
    case sourceGraphDigest
    case sourceGraphIdentifier
    case inputGraphDigest
    case inputGraphIdentifier
    case generationPipelineDigest
    case bindingTableDigest
    case bindings
    case generatedMojoSourceDigest
    case generatedCWorkerSourceDigest
    case sourceMapDigest
    case generatedMojoObjectDigest
    case generatedCWorkerObjectDigest
    case compilerVersion
    case protocolVersion
    case protocolDescriptor
    case protocolHeaderByteCount
    case protocolByteOrder
    case maximumFramePayloadBytes
    case maximumInFlightRequests
    case protocolMessageKinds
    case runtimeBundleManifestDigest
    case runtimeReceiptDigest
    case executable
    case libraries
    case loaderSearchPath
    case systemDependencies
    case programInterpreter
    case target
    case artifactIdentity
    case targetClosureDigest
}

extension MojoRuntimeWorkerBundleVerification {
    fileprivate func changingSemanticField(
        _ field: WorkerVerificationSemanticField
    ) -> MojoRuntimeWorkerBundleVerification {
        MojoRuntimeWorkerBundleVerification(
            schemaVersion: field == .schemaVersion
                ? schemaVersion + 1 : schemaVersion,
            bundleDigest: field == .bundleDigest
                ? changedDigest(bundleDigest) : bundleDigest,
            executionContractDigest: field == .executionContractDigest
                ? changedDigest(executionContractDigest)
                : executionContractDigest,
            workerABIVersion: field == .workerABIVersion
                ? workerABIVersion + 1 : workerABIVersion,
            sourceGraphDigest: field == .sourceGraphDigest
                ? changedDigest(sourceGraphDigest) : sourceGraphDigest,
            sourceGraphIdentifier: field == .sourceGraphIdentifier
                ? sourceGraphIdentifier + 1 : sourceGraphIdentifier,
            inputGraphDigest: field == .inputGraphDigest
                ? changedDigest(inputGraphDigest) : inputGraphDigest,
            inputGraphIdentifier: field == .inputGraphIdentifier
                ? inputGraphIdentifier + 1 : inputGraphIdentifier,
            generationPipelineDigest: field == .generationPipelineDigest
                ? changedDigest(generationPipelineDigest)
                : generationPipelineDigest,
            bindingTableDigest: field == .bindingTableDigest
                ? changedDigest(bindingTableDigest) : bindingTableDigest,
            bindings: field == .bindings
                ? bindings + bindings.prefix(1) : bindings,
            generatedMojoSourceDigest: field == .generatedMojoSourceDigest
                ? changedDigest(generatedMojoSourceDigest)
                : generatedMojoSourceDigest,
            generatedCWorkerSourceDigest: field
                == .generatedCWorkerSourceDigest
                ? changedDigest(generatedCWorkerSourceDigest)
                : generatedCWorkerSourceDigest,
            sourceMapDigest: field == .sourceMapDigest
                ? changedDigest(sourceMapDigest) : sourceMapDigest,
            generatedMojoObjectDigest: field == .generatedMojoObjectDigest
                ? changedDigest(generatedMojoObjectDigest)
                : generatedMojoObjectDigest,
            generatedCWorkerObjectDigest: field
                == .generatedCWorkerObjectDigest
                ? changedDigest(generatedCWorkerObjectDigest)
                : generatedCWorkerObjectDigest,
            compilerVersion: field == .compilerVersion
                ? compilerVersion + "-changed" : compilerVersion,
            protocolVersion: field == .protocolVersion
                ? protocolVersion + 1 : protocolVersion,
            protocolDescriptor: field == .protocolDescriptor
                ? protocolDescriptor + 1 : protocolDescriptor,
            protocolHeaderByteCount: field == .protocolHeaderByteCount
                ? protocolHeaderByteCount + 1 : protocolHeaderByteCount,
            protocolByteOrder: field == .protocolByteOrder
                ? protocolByteOrder + "-changed" : protocolByteOrder,
            maximumFramePayloadBytes: field == .maximumFramePayloadBytes
                ? maximumFramePayloadBytes + 1 : maximumFramePayloadBytes,
            maximumInFlightRequests: field == .maximumInFlightRequests
                ? maximumInFlightRequests + 1 : maximumInFlightRequests,
            protocolMessageKinds: field == .protocolMessageKinds
                ? protocolMessageKinds + protocolMessageKinds.prefix(1)
                : protocolMessageKinds,
            runtimeBundleManifestDigest: field
                == .runtimeBundleManifestDigest
                ? changedDigest(runtimeBundleManifestDigest)
                : runtimeBundleManifestDigest,
            runtimeReceiptDigest: field == .runtimeReceiptDigest
                ? changedDigest(runtimeReceiptDigest) : runtimeReceiptDigest,
            executable: field == .executable
                ? MojoRuntimeBundleFile(
                    relativePath: executable.relativePath + ".changed",
                    sha256Digest: executable.sha256Digest
                )
                : executable,
            libraries: field == .libraries
                ? libraries + libraries.prefix(1) : libraries,
            loaderSearchPath: field == .loaderSearchPath
                ? loaderSearchPath + ":changed" : loaderSearchPath,
            systemDependencies: field == .systemDependencies
                ? systemDependencies + ["/changed"] : systemDependencies,
            programInterpreter: field == .programInterpreter
                ? (programInterpreter ?? "/changed") + ".changed"
                : programInterpreter,
            target: field == .target
                ? MojoRuntimeBundleTarget(
                    triple: target.triple + "-changed",
                    cpu: target.cpu,
                    accelerator: target.accelerator
                )
                : target,
            artifactIdentity: field == .artifactIdentity
                ? MojoRuntimeWorkerArtifactIdentity(
                    targetName: artifactIdentity.targetName,
                    moduleName: artifactIdentity.moduleName,
                    artifactName: artifactIdentity.artifactName,
                    libraryName: artifactIdentity.libraryName,
                    symbolPrefix: artifactIdentity.symbolPrefix + "_changed"
                )
                : artifactIdentity,
            targetClosureDigest: field == .targetClosureDigest
                ? changedDigest(targetClosureDigest) : targetClosureDigest,
            verifiedBundleURL: verifiedBundleURL
        )
    }

    fileprivate func changedDigest(_ digest: String) -> String {
        String(
            repeating: digest.first == "0" ? "1" : "0",
            count: digest.count
        )
    }
}

private func workerVerificationFixture(
    at bundleURL: URL
) -> MojoRuntimeWorkerBundleVerification {
    MojoRuntimeWorkerBundleVerification(
        schemaVersion: 1,
        bundleDigest: digest("1"),
        executionContractDigest: digest("2"),
        workerABIVersion: 1,
        sourceGraphDigest: digest("3"),
        sourceGraphIdentifier: 3,
        inputGraphDigest: digest("4"),
        inputGraphIdentifier: 4,
        generationPipelineDigest: digest("5"),
        bindingTableDigest: digest("6"),
        bindings: [
            MojoRuntimeWorkerBinding(
                bindingID: 7,
                functionName: "execute",
                signature: .borrowedMutableFloat32Buffers,
                sessionFactoryFunctionName: nil
            )
        ],
        generatedMojoSourceDigest: digest("7"),
        generatedCWorkerSourceDigest: digest("8"),
        sourceMapDigest: digest("9"),
        generatedMojoObjectDigest: digest("a"),
        generatedCWorkerObjectDigest: digest("b"),
        compilerVersion: "Mojo 1.0.0",
        protocolVersion: 1,
        protocolDescriptor: 3,
        protocolHeaderByteCount: 32,
        protocolByteOrder: "little-endian",
        maximumFramePayloadBytes: 65_536,
        maximumInFlightRequests: 1,
        protocolMessageKinds: [
            MojoRuntimeWorkerMessageKind(rawValue: 1, name: "ready")
        ],
        runtimeBundleManifestDigest: digest("c"),
        runtimeReceiptDigest: digest("d"),
        executable: MojoRuntimeBundleFile(
            relativePath: "bin/worker",
            sha256Digest: digest("e")
        ),
        libraries: [
            MojoRuntimeBundleFile(
                relativePath: "lib/libAsyncRT.dylib",
                sha256Digest: digest("f")
            )
        ],
        loaderSearchPath: "@executable_path/../lib",
        systemDependencies: ["/usr/lib/libSystem.B.dylib"],
        programInterpreter: nil,
        target: MojoRuntimeBundleTarget(
            triple: "arm64-apple-macosx15.0",
            cpu: "apple-m4",
            accelerator: "metal"
        ),
        artifactIdentity: MojoRuntimeWorkerArtifactIdentity(
            targetName: "Worker",
            moduleName: "Worker",
            artifactName: "Worker",
            libraryName: "libWorker",
            symbolPrefix: "worker"
        ),
        targetClosureDigest: digest("0"),
        verifiedBundleURL: bundleURL
    )
}

private func digest(_ character: Character) -> String {
    String(repeating: character, count: 64)
}
