import MojoRuntime
import MojoRuntimeProtocolCore

package enum MojoRuntimeWorkerReadyAdmission {
    package static func validate(
        _ ready: MojoRuntimeReadyPayload,
        against verification: MojoRuntimeWorkerBundleVerification
    ) throws {
        try requireEqual(
            ready.protocolSchemaDigest,
            MojoRuntimeProtocol.schemaDigest,
            field: "protocolSchemaDigest"
        )
        try requireEqual(
            ready.executionContractDigest,
            verification.executionContractDigest,
            field: "executionContractDigest"
        )
        try requireEqual(
            ready.inputGraphDigest,
            verification.inputGraphDigest,
            field: "inputGraphDigest"
        )
        try requireEqual(
            ready.inputGraphIdentifier,
            verification.inputGraphIdentifier,
            field: "inputGraphIdentifier"
        )
        try requireEqual(
            ready.bindingTableDigest,
            verification.bindingTableDigest,
            field: "bindingTableDigest"
        )
        try requireEqual(
            ready.abiVersion,
            verification.workerABIVersion,
            field: "abiVersion"
        )
        try requireEqual(
            ready.targetTriple,
            verification.target.triple,
            field: "targetTriple"
        )
        try requireEqual(
            ready.targetCPU,
            verification.target.cpu,
            field: "targetCPU"
        )
        try requireEqual(
            ready.targetAccelerator,
            verification.target.accelerator,
            field: "targetAccelerator"
        )
        try requireEqual(
            ready.maximumFramePayloadBytes,
            verification.maximumFramePayloadBytes,
            field: "maximumFramePayloadBytes"
        )
    }

    private static func requireEqual<Value: Equatable>(
        _ actual: Value,
        _ expected: Value,
        field: String
    ) throws {
        guard actual == expected else {
            throw MojoRuntimeWorkerError.readyMismatch(field: field)
        }
    }
}
