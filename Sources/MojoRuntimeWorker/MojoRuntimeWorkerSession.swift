import MojoRuntime
public import Mojo

public protocol MojoRuntimeWorkerSession: AnyObject, Sendable {
    var capabilities: MojoSessionCapabilities { get }
    var isShutdown: Bool { get async }

    func invoke(
        _ operation: MojoRuntimeWorkerFloat32Operation,
        input: [Float],
        outputElementCount: Int,
        timeout: Duration
    ) async throws -> [Float]

    func shutdown() async throws
}

final class MojoRuntimeWorkerSessionFacade: MojoRuntimeWorkerSession {
    let capabilities: MojoSessionCapabilities
    private let attempt: MojoRuntimeWorkerAttemptActor

    package init(
        state: MojoRuntimeWorkerSessionState,
        attempt: MojoRuntimeWorkerAttemptActor
    ) {
        self.capabilities = state.capabilities
        self.attempt = attempt
    }

    var isShutdown: Bool {
        get async {
            await attempt.isShutdown()
        }
    }

    func invoke(
        _ operation: MojoRuntimeWorkerFloat32Operation,
        input: [Float],
        outputElementCount: Int,
        timeout: Duration
    ) async throws -> [Float] {
        try await attempt.invoke(
            operation,
            input: input,
            outputElementCount: outputElementCount,
            timeout: timeout
        )
    }

    func shutdown() async throws {
        try await attempt.explicitShutdown()
    }
}
