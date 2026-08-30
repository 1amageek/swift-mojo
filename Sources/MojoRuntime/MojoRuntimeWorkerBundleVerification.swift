import Foundation

public struct MojoRuntimeWorkerBundleVerification: Equatable, Sendable {
    public let schemaVersion: Int
    public let bundleDigest: String
    public let executionContractDigest: String
    public let workerABIVersion: UInt32
    public let sourceGraphDigest: String
    public let sourceGraphIdentifier: UInt64
    public let inputGraphDigest: String
    public let inputGraphIdentifier: UInt64
    public let generationPipelineDigest: String
    public let bindingTableDigest: String
    public let bindings: [MojoRuntimeWorkerBinding]
    public let generatedMojoSourceDigest: String
    public let generatedCWorkerSourceDigest: String
    public let sourceMapDigest: String
    public let generatedMojoObjectDigest: String
    public let generatedCWorkerObjectDigest: String
    public let compilerVersion: String
    public let protocolVersion: UInt16
    public let protocolDescriptor: Int32
    public let protocolHeaderByteCount: Int
    public let protocolByteOrder: String
    public let maximumFramePayloadBytes: UInt64
    public let maximumInFlightRequests: Int
    public let protocolMessageKinds: [MojoRuntimeWorkerMessageKind]
    public let runtimeBundleManifestDigest: String
    public let runtimeReceiptDigest: String
    public let executable: MojoRuntimeBundleFile
    public let libraries: [MojoRuntimeBundleFile]
    public let loaderSearchPath: String
    public let systemDependencies: [String]
    public let programInterpreter: String?
    public let target: MojoRuntimeBundleTarget
    public let artifactIdentity: MojoRuntimeWorkerArtifactIdentity
    public let targetClosureDigest: String

    package let verifiedBundleURL: URL

    package init(
        schemaVersion: Int,
        bundleDigest: String,
        executionContractDigest: String,
        workerABIVersion: UInt32,
        sourceGraphDigest: String,
        sourceGraphIdentifier: UInt64,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        generationPipelineDigest: String,
        bindingTableDigest: String,
        bindings: [MojoRuntimeWorkerBinding],
        generatedMojoSourceDigest: String,
        generatedCWorkerSourceDigest: String,
        sourceMapDigest: String,
        generatedMojoObjectDigest: String,
        generatedCWorkerObjectDigest: String,
        compilerVersion: String,
        protocolVersion: UInt16,
        protocolDescriptor: Int32,
        protocolHeaderByteCount: Int,
        protocolByteOrder: String,
        maximumFramePayloadBytes: UInt64,
        maximumInFlightRequests: Int,
        protocolMessageKinds: [MojoRuntimeWorkerMessageKind],
        runtimeBundleManifestDigest: String,
        runtimeReceiptDigest: String,
        executable: MojoRuntimeBundleFile,
        libraries: [MojoRuntimeBundleFile],
        loaderSearchPath: String,
        systemDependencies: [String],
        programInterpreter: String?,
        target: MojoRuntimeBundleTarget,
        artifactIdentity: MojoRuntimeWorkerArtifactIdentity,
        targetClosureDigest: String,
        verifiedBundleURL: URL
    ) {
        self.schemaVersion = schemaVersion
        self.bundleDigest = bundleDigest
        self.executionContractDigest = executionContractDigest
        self.workerABIVersion = workerABIVersion
        self.sourceGraphDigest = sourceGraphDigest
        self.sourceGraphIdentifier = sourceGraphIdentifier
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.generationPipelineDigest = generationPipelineDigest
        self.bindingTableDigest = bindingTableDigest
        self.bindings = bindings
        self.generatedMojoSourceDigest = generatedMojoSourceDigest
        self.generatedCWorkerSourceDigest = generatedCWorkerSourceDigest
        self.sourceMapDigest = sourceMapDigest
        self.generatedMojoObjectDigest = generatedMojoObjectDigest
        self.generatedCWorkerObjectDigest = generatedCWorkerObjectDigest
        self.compilerVersion = compilerVersion
        self.protocolVersion = protocolVersion
        self.protocolDescriptor = protocolDescriptor
        self.protocolHeaderByteCount = protocolHeaderByteCount
        self.protocolByteOrder = protocolByteOrder
        self.maximumFramePayloadBytes = maximumFramePayloadBytes
        self.maximumInFlightRequests = maximumInFlightRequests
        self.protocolMessageKinds = protocolMessageKinds
        self.runtimeBundleManifestDigest = runtimeBundleManifestDigest
        self.runtimeReceiptDigest = runtimeReceiptDigest
        self.executable = executable
        self.libraries = libraries
        self.loaderSearchPath = loaderSearchPath
        self.systemDependencies = systemDependencies
        self.programInterpreter = programInterpreter
        self.target = target
        self.artifactIdentity = artifactIdentity
        self.targetClosureDigest = targetClosureDigest
        self.verifiedBundleURL = verifiedBundleURL.standardizedFileURL
    }

    package func hasSameRuntimeSemantics(
        as other: MojoRuntimeWorkerBundleVerification
    ) -> Bool {
        // Rebase only the private location before using synthesized equality so
        // every stored semantic field remains part of admission.
        MojoRuntimeWorkerBundleVerification(
            schemaVersion: schemaVersion,
            bundleDigest: bundleDigest,
            executionContractDigest: executionContractDigest,
            workerABIVersion: workerABIVersion,
            sourceGraphDigest: sourceGraphDigest,
            sourceGraphIdentifier: sourceGraphIdentifier,
            inputGraphDigest: inputGraphDigest,
            inputGraphIdentifier: inputGraphIdentifier,
            generationPipelineDigest: generationPipelineDigest,
            bindingTableDigest: bindingTableDigest,
            bindings: bindings,
            generatedMojoSourceDigest: generatedMojoSourceDigest,
            generatedCWorkerSourceDigest: generatedCWorkerSourceDigest,
            sourceMapDigest: sourceMapDigest,
            generatedMojoObjectDigest: generatedMojoObjectDigest,
            generatedCWorkerObjectDigest: generatedCWorkerObjectDigest,
            compilerVersion: compilerVersion,
            protocolVersion: protocolVersion,
            protocolDescriptor: protocolDescriptor,
            protocolHeaderByteCount: protocolHeaderByteCount,
            protocolByteOrder: protocolByteOrder,
            maximumFramePayloadBytes: maximumFramePayloadBytes,
            maximumInFlightRequests: maximumInFlightRequests,
            protocolMessageKinds: protocolMessageKinds,
            runtimeBundleManifestDigest: runtimeBundleManifestDigest,
            runtimeReceiptDigest: runtimeReceiptDigest,
            executable: executable,
            libraries: libraries,
            loaderSearchPath: loaderSearchPath,
            systemDependencies: systemDependencies,
            programInterpreter: programInterpreter,
            target: target,
            artifactIdentity: artifactIdentity,
            targetClosureDigest: targetClosureDigest,
            verifiedBundleURL: other.verifiedBundleURL
        ) == other
    }
}
