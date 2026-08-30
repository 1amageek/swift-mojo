import Foundation
import MojoPOSIXSupport
import Synchronization

package final class MojoRuntimeWorkerCancellationGate: Sendable {
    package struct Lease: Sendable {
        package let generation: UInt64
        fileprivate let gate: MojoRuntimeWorkerCancellationGate

        package func cancel() {
            gate.cancel(generation: generation)
        }
    }

    private enum ExchangePhase: Sendable {
        case open
        case cancelRequested
        case responseCommitted
    }

    private struct ActiveExchange: Sendable {
        let generation: UInt64
        let shielded: Bool
        var phase: ExchangePhase
    }

    private struct State: Sendable {
        var nextGeneration: UInt64 = 0
        var scopeCancelled = false
        var closed = false
        var active: ActiveExchange?
        var signalerCount = 0
        var handlerCount = 0
        var signalFailed = false
    }

    private let wakeup: MojoPOSIXWorkerWakeup
    private let state = Mutex(State())

    package init(wakeup: MojoPOSIXWorkerWakeup) {
        self.wakeup = wakeup
    }

    package func beginExchange(shielded: Bool = false) throws -> Lease {
        try state.withLock { state in
            guard !state.closed else {
                throw MojoRuntimeWorkerError.attemptClosed
            }
            guard shielded || !state.scopeCancelled else {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            guard state.active == nil else {
                throw MojoRuntimeWorkerError.sessionBusy
            }
            guard state.nextGeneration < UInt64.max else {
                throw MojoRuntimeWorkerError.protocolFailure
            }
            state.nextGeneration += 1
            let generation = state.nextGeneration
            state.active = ActiveExchange(
                generation: generation,
                shielded: shielded,
                phase: .open
            )
            return Lease(generation: generation, gate: self)
        }
    }

    package func cancelScope() {
        requestCancellation(scope: true, generation: nil)
    }

    package func isCancellationRequested(for lease: Lease) -> Bool {
        state.withLock { state in
            guard let active = state.active,
                  active.generation == lease.generation else {
                return true
            }
            return active.phase == .cancelRequested
                && !active.shielded
        }
    }

    package func commitResponse(for lease: Lease) -> Bool {
        state.withLock { state in
            guard !state.closed,
                  let active = state.active,
                  active.generation == lease.generation,
                  active.phase == .open else {
                return false
            }
            state.active?.phase = .responseCommitted
            return true
        }
    }

    package func endExchange(for lease: Lease) {
        state.withLock { state in
            guard state.active?.generation == lease.generation else {
                return
            }
            state.active = nil
        }
    }

    package func beginHandler() {
        state.withLock { state in
            state.handlerCount += 1
        }
    }

    package func endHandler() {
        state.withLock { state in
            if state.handlerCount > 0 {
                state.handlerCount -= 1
            }
        }
    }

    package func drainWakeup() throws -> MojoPOSIXWorkerWakeupDrain {
        try MojoPOSIXWorkerSupport.drainWakeup(wakeup)
    }

    package var wakeupDescriptor: Int32 {
        wakeup.readDescriptor
    }

    package func close(
        deadline: ContinuousClock.Instant
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        let shouldSignal = state.withLock { state -> Bool in
            state.closed = true
            state.scopeCancelled = true
            guard let active = state.active,
                  active.phase == .open,
                  !active.shielded else {
                return false
            }
            state.active?.phase = .cancelRequested
            state.signalerCount += 1
            return true
        }

        if shouldSignal {
            do {
                try MojoPOSIXWorkerSupport.signalWakeup(wakeup)
            } catch {
                state.withLock { state in
                    state.signalFailed = true
                }
            }
            finishSignal()
        }

        while true {
            let activeOperations = state.withLock { state in
                state.signalerCount + state.handlerCount
            }
            guard activeOperations > 0 else { break }
            guard ContinuousClock().now < deadline else { break }
            Thread.sleep(forTimeInterval: 0.001)
        }

        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        let operationsRemain = state.withLock { state in
            state.signalerCount > 0 || state.handlerCount > 0
        }
        if operationsRemain {
            failures.append(.wakeupCloseFailed)
            return failures
        }
        let signalFailed = state.withLock { $0.signalFailed }
        if signalFailed {
            failures.append(.wakeupSignalFailed)
        }
        for descriptor in [wakeup.readDescriptor, wakeup.writeDescriptor] {
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
            } catch {
                failures.append(.wakeupCloseFailed)
            }
        }
        return failures
    }

    private func cancel(generation: UInt64) {
        requestCancellation(scope: false, generation: generation)
    }

    private func requestCancellation(
        scope: Bool,
        generation: UInt64?
    ) {
        let shouldSignal = state.withLock { state -> Bool in
            if scope {
                state.scopeCancelled = true
            }
            guard !state.closed,
                  let active = state.active,
                  (generation == nil || active.generation == generation),
                  active.phase == .open,
                  !active.shielded else {
                return false
            }
            state.active?.phase = .cancelRequested
            state.signalerCount += 1
            return true
        }
        guard shouldSignal else { return }
        do {
            try MojoPOSIXWorkerSupport.signalWakeup(wakeup)
        } catch {
            state.withLock { state in
                state.signalFailed = true
            }
        }
        finishSignal()
    }

    private func finishSignal() {
        state.withLock { state in
            if state.signalerCount > 0 {
                state.signalerCount -= 1
            }
        }
    }
}
