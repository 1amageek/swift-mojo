import Foundation
import MojoRuntime
import MojoRuntimeProtocolCore

enum MojoRuntimeWorkerTestFixture {
    static func digest(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    static func bindings() -> [MojoRuntimeWorkerBinding] {
        let factory = MojoRuntimeWorkerBinding(
            bindingID: 1,
            functionName: "createSession",
            signature: .runtimeSessionFactory,
            sessionFactoryFunctionName: nil
        )
        return [
            factory,
            MojoRuntimeWorkerBinding(
                bindingID: 2,
                functionName: "invoke",
                signature: .sessionBorrowedMutableFloat32Buffers,
                sessionFactoryFunctionName: factory.functionName
            ),
        ]
    }

    static func verification(
        bundleURL: URL,
        bundleDigest: String? = nil,
        maximumFramePayloadBytes: UInt64 = 65_536
    ) -> MojoRuntimeWorkerBundleVerification {
        MojoRuntimeWorkerBundleVerification(
            schemaVersion: 1,
            bundleDigest: bundleDigest ?? digest("a"),
            executionContractDigest: digest("b"),
            workerABIVersion: 1,
            sourceGraphDigest: digest("c"),
            sourceGraphIdentifier: 11,
            inputGraphDigest: digest("d"),
            inputGraphIdentifier: 12,
            generationPipelineDigest: digest("e"),
            bindingTableDigest: digest("f"),
            bindings: bindings(),
            generatedMojoSourceDigest: digest("1"),
            generatedCWorkerSourceDigest: digest("2"),
            sourceMapDigest: digest("3"),
            generatedMojoObjectDigest: digest("4"),
            generatedCWorkerObjectDigest: digest("5"),
            compilerVersion: "Mojo 1.0.0",
            protocolVersion: MojoRuntimeProtocol.version,
            protocolDescriptor: 3,
            protocolHeaderByteCount: MojoRuntimeProtocol.headerByteCount,
            protocolByteOrder: "littleEndian",
            maximumFramePayloadBytes: maximumFramePayloadBytes,
            maximumInFlightRequests: 1,
            protocolMessageKinds: [],
            runtimeBundleManifestDigest: digest("6"),
            runtimeReceiptDigest: digest("7"),
            executable: MojoRuntimeBundleFile(
                relativePath: "bin/worker",
                sha256Digest: digest("8")
            ),
            libraries: [],
            loaderSearchPath: "@executable_path/../lib",
            systemDependencies: [],
            programInterpreter: nil,
            target: MojoRuntimeBundleTarget(
                triple: "arm64-apple-macosx",
                cpu: "apple-m4",
                accelerator: "metal"
            ),
            artifactIdentity: MojoRuntimeWorkerArtifactIdentity(
                targetName: "Worker",
                moduleName: "Worker",
                artifactName: "Worker",
                libraryName: "Worker",
                symbolPrefix: "worker"
            ),
            targetClosureDigest: digest("9"),
            verifiedBundleURL: bundleURL
        )
    }

    static func rebased(
        _ verification: MojoRuntimeWorkerBundleVerification,
        to bundleURL: URL,
        bundleDigest: String? = nil
    ) -> MojoRuntimeWorkerBundleVerification {
        MojoRuntimeWorkerBundleVerification(
            schemaVersion: verification.schemaVersion,
            bundleDigest: bundleDigest ?? verification.bundleDigest,
            executionContractDigest: verification.executionContractDigest,
            workerABIVersion: verification.workerABIVersion,
            sourceGraphDigest: verification.sourceGraphDigest,
            sourceGraphIdentifier: verification.sourceGraphIdentifier,
            inputGraphDigest: verification.inputGraphDigest,
            inputGraphIdentifier: verification.inputGraphIdentifier,
            generationPipelineDigest: verification.generationPipelineDigest,
            bindingTableDigest: verification.bindingTableDigest,
            bindings: verification.bindings,
            generatedMojoSourceDigest:
                verification.generatedMojoSourceDigest,
            generatedCWorkerSourceDigest:
                verification.generatedCWorkerSourceDigest,
            sourceMapDigest: verification.sourceMapDigest,
            generatedMojoObjectDigest:
                verification.generatedMojoObjectDigest,
            generatedCWorkerObjectDigest:
                verification.generatedCWorkerObjectDigest,
            compilerVersion: verification.compilerVersion,
            protocolVersion: verification.protocolVersion,
            protocolDescriptor: verification.protocolDescriptor,
            protocolHeaderByteCount:
                verification.protocolHeaderByteCount,
            protocolByteOrder: verification.protocolByteOrder,
            maximumFramePayloadBytes:
                verification.maximumFramePayloadBytes,
            maximumInFlightRequests:
                verification.maximumInFlightRequests,
            protocolMessageKinds: verification.protocolMessageKinds,
            runtimeBundleManifestDigest:
                verification.runtimeBundleManifestDigest,
            runtimeReceiptDigest: verification.runtimeReceiptDigest,
            executable: verification.executable,
            libraries: verification.libraries,
            loaderSearchPath: verification.loaderSearchPath,
            systemDependencies: verification.systemDependencies,
            programInterpreter: verification.programInterpreter,
            target: verification.target,
            artifactIdentity: verification.artifactIdentity,
            targetClosureDigest: verification.targetClosureDigest,
            verifiedBundleURL: bundleURL
        )
    }

    static func ready(
        for verification: MojoRuntimeWorkerBundleVerification,
        executionContractDigest: String? = nil,
        inputGraphDigest: String? = nil,
        inputGraphIdentifier: UInt64? = nil,
        bindingTableDigest: String? = nil,
        abiVersion: UInt32? = nil,
        targetTriple: String? = nil,
        targetCPU: String? = nil,
        targetAccelerator: String?? = nil,
        maximumFramePayloadBytes: UInt64? = nil
    ) throws -> MojoRuntimeReadyPayload {
        try MojoRuntimeReadyPayload(
            executionContractDigest:
                executionContractDigest
                ?? verification.executionContractDigest,
            inputGraphDigest:
                inputGraphDigest ?? verification.inputGraphDigest,
            inputGraphIdentifier:
                inputGraphIdentifier ?? verification.inputGraphIdentifier,
            bindingTableDigest:
                bindingTableDigest ?? verification.bindingTableDigest,
            abiVersion: abiVersion ?? verification.workerABIVersion,
            targetTriple: targetTriple ?? verification.target.triple,
            targetCPU: targetCPU ?? verification.target.cpu,
            targetAccelerator:
                targetAccelerator ?? verification.target.accelerator,
            maximumFramePayloadBytes:
                maximumFramePayloadBytes
                ?? verification.maximumFramePayloadBytes
        )
    }

    static func readyFrameData(
        for verification: MojoRuntimeWorkerBundleVerification
    ) throws -> Data {
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes:
                verification.maximumFramePayloadBytes
        )
        let frame = try MojoRuntimeFrame(
            requestID: 0,
            payload: .ready(try ready(for: verification)),
            limits: limits
        )
        return try frame.encodedData(limits: limits)
    }

    static func shellOctal(_ data: Data) -> String {
        data.map { String(format: "\\%03o", $0) }.joined()
    }
}
