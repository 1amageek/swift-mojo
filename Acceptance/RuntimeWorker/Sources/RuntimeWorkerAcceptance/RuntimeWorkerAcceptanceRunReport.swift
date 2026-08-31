import Foundation

/// Lossless, non-receipt handoff from the actual RT4.B acceptance run.
///
/// The artifact, protocol, boundary, environment, and lifecycle values are
/// the canonical records that a later 4.A mapper may use to construct a
/// receipt. Derived counts and Float32 bit patterns remain diagnostics and do
/// not replace any canonical record.
public struct RuntimeWorkerAcceptanceRunReport: Codable, Equatable, Sendable {
    public let artifact: RuntimeWorkerAcceptanceContract.Artifact
    public let protocolRecord: RuntimeWorkerAcceptanceContract.ProtocolRecord
    public let consumerBoundary:
        RuntimeWorkerAcceptanceContract.ConsumerBoundary
    public let executionEnvironment:
        RuntimeWorkerAcceptanceContract.ExecutionEnvironment
    public let lifecycle: RuntimeWorkerAcceptanceContract.Lifecycle
    public let projectionFieldCount: Int
    public let firstAttemptOutputBitPatterns: [UInt32]
    public let forcedFailureError: String
    public let thirdAttemptOutputBitPatterns: [UInt32]
    public let stageLeakCount: Int
    public let processLeakCount: Int

    public init(
        artifact: RuntimeWorkerAcceptanceContract.Artifact,
        protocolRecord: RuntimeWorkerAcceptanceContract.ProtocolRecord,
        projectionFieldCount: Int,
        consumerBoundary: RuntimeWorkerAcceptanceContract.ConsumerBoundary,
        executionEnvironment:
            RuntimeWorkerAcceptanceContract.ExecutionEnvironment,
        lifecycle: RuntimeWorkerAcceptanceContract.Lifecycle,
        firstAttemptOutputBitPatterns: [UInt32],
        forcedFailureError: String,
        thirdAttemptOutputBitPatterns: [UInt32],
        stageLeakCount: Int,
        processLeakCount: Int
    ) {
        self.artifact = artifact
        self.protocolRecord = protocolRecord
        self.projectionFieldCount = projectionFieldCount
        self.consumerBoundary = consumerBoundary
        self.executionEnvironment = executionEnvironment
        self.lifecycle = lifecycle
        self.firstAttemptOutputBitPatterns = firstAttemptOutputBitPatterns
        self.forcedFailureError = forcedFailureError
        self.thirdAttemptOutputBitPatterns = thirdAttemptOutputBitPatterns
        self.stageLeakCount = stageLeakCount
        self.processLeakCount = processLeakCount
    }
}

struct ConsumerRunReport: Codable, Equatable, Sendable {
    let firstAttemptOutputBitPatterns: [UInt32]
    let forcedFailureError: String
    let forcedFailureTimedOut: Bool
    let forcedFailurePartialOutputElementCount: Int
    let forcedFailureCleanupFailureCount: Int
    let thirdAttemptOutputBitPatterns: [UInt32]
    let executionPathIsolated: Bool
    let cleanEnvironmentObserved: Bool
}
