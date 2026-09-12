/// Resource retention and admission state shared by all copies of a worker.
public struct MojoRuntimeWorkerLifetimeStatus: Equatable, Sendable {
    public let isActive: Bool
    public let isAdmissionClosed: Bool
    public let retainedInputByteCount: UInt64
    public let recoveryFailures: [MojoRuntimeWorkerCleanupFailure]
}
