import Foundation
import MojoPOSIXSupport
import MojoRuntimeWorker
import Synchronization
import Testing

@Suite("Mojo runtime worker lifetime")
struct MojoRuntimeWorkerLifetimeTests {
    @Test(.timeLimit(.minutes(1)))
    func admissionHasOneReservationAcrossConcurrentCallers() async {
        let lifetime = MojoRuntimeWorkerLifetime()
        let admitted = Mutex(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    do {
                        try lifetime.begin()
                        admitted.withLock { $0 += 1 }
                    } catch {
                        #expect(error as? MojoRuntimeWorkerError == .operationInProgress)
                    }
                }
            }
        }
        #expect(admitted.withLock { $0 } == 1)
        #expect(lifetime.status.isActive)
        lifetime.finish()
        #expect(!lifetime.status.isActive)
        do {
            try lifetime.begin()
            lifetime.finish()
        } catch {
            Issue.record("Released reservation must be reusable: \(error)")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func quarantineRemainsClosedAndReportsRetainedBytesUntilProof() async throws {
        let probe = LifetimeProbe()
        defer { probe.allowTermination() }
        let lifetime = try quarantinedLifetime(probe)
        lifetime.finish()
        #expect(lifetime.status.isAdmissionClosed)
        #expect(lifetime.status.retainedInputByteCount == 8)
        #expect(throws: MojoRuntimeWorkerError.attemptClosed) { try lifetime.begin() }
        try await wait { probe.snapshot.observations > 0 }
        #expect(probe.snapshot.released == 0)
        #expect(probe.snapshot.borrows == 0)
        probe.allowTermination()
        try await wait { probe.snapshot.released == 1 }
        #expect(probe.snapshot.reaps == 1)
        #expect(lifetime.status.retainedInputByteCount == 0)
        #expect(lifetime.status.recoveryFailures.isEmpty)
        #expect(lifetime.status.isAdmissionClosed)
    }

    @Test(.timeLimit(.minutes(1)))
    func recoveryRetainsProducerAfterAllCallerReferencesAreDestroyed() async throws {
        let probe = LifetimeProbe()
        defer { probe.allowTermination() }
        // The helper's result and every source/buffer reference are discarded.
        _ = try quarantinedLifetime(probe)
        try await wait { probe.snapshot.observations >= 2 }
        #expect(probe.snapshot.released == 0)
        probe.allowTermination()
        try await wait { probe.snapshot.released == 1 }
        #expect(probe.snapshot.reaps == 1)
        #expect(probe.snapshot.borrows == 0)
    }

    private func quarantinedLifetime(_ probe: LifetimeProbe) throws -> MojoRuntimeWorkerLifetime {
        let lifetime = MojoRuntimeWorkerLifetime()
        try lifetime.begin()
        let buffer = try MojoReadOnlyBuffer(hostSource: LifetimeSource(probe: probe))
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in .running },
            inspectGroup: { _ in probe.inspect() },
            signalGroup: { _, _ in },
            reapChild: { _ in probe.reap(); return 0 }
        )
        lifetime.retainAfterUnconfirmedCleanup(
            processID: 42, stageRoot: nil, inputs: [buffer], retainedByteCount: 8,
            outcome: .init(reaped: false, groupTerminationConfirmed: false,
                           failures: [.processInspectionFailed]),
            terminationGracePeriod: .milliseconds(1), forcedCleanup: .milliseconds(5),
            processControl: control
        )
        return lifetime
    }

    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock().now < deadline else { throw LifetimeTestError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum LifetimeTestError: Error { case timedOut }

private final class LifetimeProbe: Sendable {
    struct State {
        var terminated = false
        var observations = 0
        var reaps = 0
        var borrows = 0
        var released = 0
    }
    private let state = Mutex(State())
    var snapshot: State { state.withLock { $0 } }
    func allowTermination() { state.withLock { $0.terminated = true } }
    func inspect() -> MojoPOSIXProcessGroupState {
        state.withLock {
            $0.observations += 1
            return $0.terminated ? .gone : .indeterminate
        }
    }
    func reap() { state.withLock { $0.reaps += 1 } }
    func borrow() { state.withLock { $0.borrows += 1 } }
    func release() { state.withLock { $0.released += 1 } }
}

private final class LifetimeSource: MojoBufferSource {
    let byteCount = 8
    let probe: LifetimeProbe
    private let data = Data(repeating: 7, count: 8)
    init(probe: LifetimeProbe) { self.probe = probe }
    deinit { probe.release() }
    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        probe.borrow()
        return try data.withUnsafeBytes(body)
    }
}
