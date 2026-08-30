import Foundation
import MojoRuntime
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Mojo runtime worker ready admission")
struct MojoRuntimeWorkerReadyAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func admitsOnlyTheCompleteVerifiedReadyIdentity() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
        )
        try MojoRuntimeWorkerReadyAdmission.validate(
            MojoRuntimeWorkerTestFixture.ready(for: verification),
            against: verification
        )

        let mutations: [(
            field: String,
            ready: () throws -> MojoRuntimeReadyPayload
        )] = [
            (
                "executionContractDigest",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        executionContractDigest:
                            MojoRuntimeWorkerTestFixture.digest("0")
                    )
                }
            ),
            (
                "inputGraphDigest",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        inputGraphDigest:
                            MojoRuntimeWorkerTestFixture.digest("0")
                    )
                }
            ),
            (
                "inputGraphIdentifier",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        inputGraphIdentifier:
                            verification.inputGraphIdentifier + 1
                    )
                }
            ),
            (
                "bindingTableDigest",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        bindingTableDigest:
                            MojoRuntimeWorkerTestFixture.digest("0")
                    )
                }
            ),
            (
                "abiVersion",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        abiVersion: verification.workerABIVersion + 1
                    )
                }
            ),
            (
                "targetTriple",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        targetTriple: "aarch64-unknown-linux-gnu"
                    )
                }
            ),
            (
                "targetCPU",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        targetCPU: "generic"
                    )
                }
            ),
            (
                "targetAccelerator",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        targetAccelerator: .some("cuda")
                    )
                }
            ),
            (
                "maximumFramePayloadBytes",
                {
                    try MojoRuntimeWorkerTestFixture.ready(
                        for: verification,
                        maximumFramePayloadBytes:
                            verification.maximumFramePayloadBytes / 2
                    )
                }
            ),
        ]

        for mutation in mutations {
            #expect(
                throws: MojoRuntimeWorkerError.readyMismatch(
                    field: mutation.field
                )
            ) {
                try MojoRuntimeWorkerReadyAdmission.validate(
                    mutation.ready(),
                    against: verification
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func codecRejectsAMutatedProtocolSchemaBeforeReadyAdmission() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
        )
        var frameData = try MojoRuntimeWorkerTestFixture.readyFrameData(
            for: verification
        )
        let schemaBytes = Data(MojoRuntimeProtocol.schemaDigest.utf8)
        let range = try #require(frameData.range(of: schemaBytes))
        frameData[range.lowerBound] = frameData[range.lowerBound] == 48 ? 49 : 48
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes:
                verification.maximumFramePayloadBytes
        )

        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decode(frameData, limits: limits)
        }
    }
}
