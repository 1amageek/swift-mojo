import Foundation
import MojoPOSIXSupport
import Synchronization

package final class MojoRuntimeWorkerLifetime: Sendable {
    private struct State {
        var active = false
        var closed = false
        var retainedBytes: UInt64 = 0
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
    }
    private let state = Mutex(State())

    package init() {}

    package var status: MojoRuntimeWorkerLifetimeStatus {
        state.withLock {
            MojoRuntimeWorkerLifetimeStatus(
                isActive: $0.active, isAdmissionClosed: $0.closed,
                retainedInputByteCount: $0.retainedBytes,
                recoveryFailures: $0.failures
            )
        }
    }

    package func begin() throws {
        try state.withLock {
            guard !$0.closed else { throw MojoRuntimeWorkerError.attemptClosed }
            guard !$0.active else { throw MojoRuntimeWorkerError.operationInProgress }
            $0.active = true
        }
    }

    package func finish() {
        state.withLock { $0.active = false }
    }

    /// The unique terminal-cleanup owner transfers already-admitted inputs here.
    /// Byte count is the invocation's validated aggregate, including aliased owners once.
    package func retainAfterUnconfirmedCleanup(
        processID: MojoPOSIXSupport.ProcessID,
        stageRoot: URL?,
        inputs: [MojoReadOnlyBuffer],
        retainedByteCount: UInt64,
        outcome: MojoRuntimeWorkerProcessLifetimeOutcome,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration,
        processControl: MojoRuntimeWorkerProcessControl = .live
    ) {
        guard !outcome.reaped || !outcome.groupTerminationConfirmed else { return }
        let claimed = state.withLock {
            guard !$0.closed else { return false }
            $0.closed = true
            $0.retainedBytes = retainedByteCount
            $0.failures = outcome.failures
            return true
        }
        precondition(claimed, "Only the unique terminal cleanup owner may transfer readers")
        // No handle is exposed: caller task cancellation cannot cancel this obligation.
        Task.detached { [self, inputs] in
            let clock = ContinuousClock()
            while true {
                do {
                    try await Task.sleep(for: forcedCleanup)
                } catch {
                    // An interrupted wait does not qualify release or abandon readers.
                    state.withLock { $0.failures = [.recoveryWaitInterrupted] }
                    await Task.yield()
                    continue
                }
                let terminationDeadline = clock.now.advanced(by: terminationGracePeriod)
                let recovered = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
                    processID: processID, mode: .hard,
                    gracefulDeadline: clock.now,
                    terminationDeadline: terminationDeadline,
                    forcedCleanupDeadline: terminationDeadline.advanced(by: forcedCleanup),
                    processControl: processControl
                )
                guard recovered.reaped && recovered.groupTerminationConfirmed else {
                    state.withLock { $0.failures = recovered.failures }
                    continue
                }
                var failures = recovered.failures
                if let stageRoot,
                   let failure = MojoRuntimeWorkerArtifactAdmission.finalizePrivateStage(
                    at: stageRoot, processLifetimeEnded: true
                   ) {
                    failures.append(failure)
                }
                // Keep producer leases through the actual terminal observation and
                // stage finalization. Their destruction occurs outside the mutex.
                withExtendedLifetime(inputs) {}
                state.withLock {
                    $0.retainedBytes = 0
                    $0.failures = failures
                }
                return
            }
        }
    }
}
