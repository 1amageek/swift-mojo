import Foundation
import MojoPOSIXSupport

package enum MojoRuntimeWorkerTerminalizer {
    package enum Mode: Sendable {
        case graceful
        case hard
    }

    package static func cleanup(
        process: MojoPOSIXWorkerProcess,
        stageRoot: URL,
        gate: MojoRuntimeWorkerCancellationGate,
        mode: Mode,
        gracefulDeadline: ContinuousClock.Instant,
        terminationDeadline: ContinuousClock.Instant,
        forcedCleanupDeadline: ContinuousClock.Instant
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        // Closing the protocol endpoint before escalation prevents a blocked
        // child write from surviving the owner's terminal transition. The
        // descriptor is owned by this single cleanup claim and is never
        // retried after a close attempt.
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                process.protocolDescriptor
            )
        } catch {
            failures.append(.transportCloseFailed)
        }
        failures.append(contentsOf: gate.close(deadline: forcedCleanupDeadline))

        let initiallyReaped: Bool
        switch mode {
        case .graceful:
            drainDiagnostics(
                descriptor: process.diagnosticDescriptor,
                deadline: gracefulDeadline
            )
            let result = waitForReap(
                processID: process.processID,
                until: gracefulDeadline,
                diagnosticDescriptor: process.diagnosticDescriptor,
                requireSuccessfulExit: true
            )
            failures.append(contentsOf: result.failures)
            initiallyReaped = result.reaped
        case .hard:
            initiallyReaped = false
        }

        var reaped = initiallyReaped
        if !reaped {
            let termination = terminateWithEscalation(
                processID: process.processID,
                terminationDeadline: terminationDeadline,
                forcedCleanupDeadline: forcedCleanupDeadline,
                diagnosticDescriptor: process.diagnosticDescriptor
            )
            failures.append(contentsOf: termination.failures)
            reaped = termination.reaped
        }

        // A direct child can be reaped while descendants remain in its
        // process group. The stage is removable only after this confirmation.
        let groupGone = terminateRemainingGroupIfNeeded(
            processID: process.processID,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedCleanupDeadline,
            diagnosticDescriptor: process.diagnosticDescriptor,
            failures: &failures
        )

        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                process.diagnosticDescriptor
            )
        } catch {
            failures.append(.diagnosticsCloseFailed)
        }

        let processLifetimeEnded = reaped && groupGone
        if let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded: processLifetimeEnded
            ) {
            failures.append(stageFailure)
        }
        return failures
    }

    package static func cleanupAdmissionFailure(
        process: MojoPOSIXWorkerProcess,
        stageRoot: URL?,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        let clock = ContinuousClock()
        let terminationDeadline = clock.now.advanced(
            by: terminationGracePeriod
        )
        let forcedDeadline = terminationDeadline.advanced(by: forcedCleanup)
        // Admission failures occur before the gate exists. A hard cleanup
        // still follows the same escalation and descriptor/stage order.
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                process.protocolDescriptor
            )
        } catch {
            failures.append(.transportCloseFailed)
        }
        let termination = terminateWithEscalation(
            processID: process.processID,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedDeadline,
            diagnosticDescriptor: process.diagnosticDescriptor
        )
        failures.append(contentsOf: termination.failures)
        let groupGone = terminateRemainingGroupIfNeeded(
            processID: process.processID,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedDeadline,
            diagnosticDescriptor: process.diagnosticDescriptor,
            failures: &failures
        )
        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                process.diagnosticDescriptor
            )
        } catch {
            failures.append(.diagnosticsCloseFailed)
        }
        if let stageRoot,
           let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded: termination.reaped && groupGone
            ) {
            failures.append(stageFailure)
        }
        return failures
    }

    private struct WaitOutcome {
        let reaped: Bool
        let failures: [MojoRuntimeWorkerCleanupFailure]
    }

    private static func waitForReap(
        processID: MojoPOSIXSupport.ProcessID,
        until deadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32? = nil,
        requireSuccessfulExit: Bool = false
    ) -> WaitOutcome {
        let clock = ContinuousClock()
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        while clock.now < deadline {
            do {
                if let waitStatus = try MojoPOSIXSupport.waitNoHang(
                    processID: processID
                ) {
                    if requireSuccessfulExit,
                       MojoPOSIXSupport.exitStatus(from: waitStatus) != 0 {
                        failures.append(.processTerminationFailed)
                    }
                    return WaitOutcome(reaped: true, failures: failures)
                }
            } catch let error as MojoPOSIXSupportError {
                if error == .childAlreadyReaped {
                    failures.append(.processInspectionFailed)
                    return WaitOutcome(reaped: true, failures: failures)
                }
                failures.append(.processReapFailed)
                return WaitOutcome(reaped: false, failures: failures)
            } catch {
                failures.append(.processReapFailed)
                return WaitOutcome(reaped: false, failures: failures)
            }
            if let diagnosticDescriptor {
                drainDiagnostics(
                    descriptor: diagnosticDescriptor,
                    deadline: deadline
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return WaitOutcome(reaped: false, failures: failures)
    }

    private static func terminateWithEscalation(
        processID: MojoPOSIXSupport.ProcessID,
        terminationDeadline: ContinuousClock.Instant,
        forcedCleanupDeadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32? = nil
    ) -> WaitOutcome {
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        var reaped = false

        // A crashed worker can remain as a zombie while its process group is
        // still observable. Reap the direct child before signalling the
        // group; otherwise an already-ended worker can be reported as a
        // signal failure.
        do {
            if try MojoPOSIXSupport.waitNoHang(processID: processID) != nil {
                return WaitOutcome(reaped: true, failures: failures)
            }
        } catch let error as MojoPOSIXSupportError {
            if error == .childAlreadyReaped {
                failures.append(.processInspectionFailed)
                return WaitOutcome(reaped: true, failures: failures)
            }
            failures.append(.processReapFailed)
        } catch {
            failures.append(.processReapFailed)
        }

        if !MojoPOSIXSupport.processGroupIsAlive(processID) {
            let result = waitForReap(
                processID: processID,
                until: forcedCleanupDeadline,
                diagnosticDescriptor: diagnosticDescriptor
            )
            return result
        }

        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: MojoPOSIXSupport.terminationSignal
            )
        } catch {
            if MojoPOSIXSupport.processGroupIsAlive(processID) {
                failures.append(.processTerminationFailed)
            }
        }

        let graceful = waitForReap(
            processID: processID,
            until: terminationDeadline,
            diagnosticDescriptor: diagnosticDescriptor
        )
        failures.append(contentsOf: graceful.failures)
        reaped = graceful.reaped

        if reaped && MojoPOSIXSupport.processGroupIsAlive(processID) {
            waitForGroupExit(
                processID: processID,
                until: terminationDeadline,
                diagnosticDescriptor: diagnosticDescriptor
            )
        }

        if !reaped || MojoPOSIXSupport.processGroupIsAlive(processID) {
            do {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: processID,
                    signal: MojoPOSIXSupport.killSignal
                )
            } catch {
                if MojoPOSIXSupport.processGroupIsAlive(processID) {
                    failures.append(.processTerminationFailed)
                }
            }
            if reaped {
                waitForGroupExit(
                    processID: processID,
                    until: forcedCleanupDeadline,
                    diagnosticDescriptor: diagnosticDescriptor
                )
            } else {
                let forced = waitForReap(
                    processID: processID,
                    until: forcedCleanupDeadline,
                    diagnosticDescriptor: diagnosticDescriptor
                )
                failures.append(contentsOf: forced.failures)
                reaped = forced.reaped
            }
        }
        if !reaped {
            failures.append(.processReapFailed)
        }
        return WaitOutcome(reaped: reaped, failures: failures)
    }

    private static func terminateRemainingGroupIfNeeded(
        processID: MojoPOSIXSupport.ProcessID,
        terminationDeadline: ContinuousClock.Instant,
        forcedCleanupDeadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32,
        failures: inout [MojoRuntimeWorkerCleanupFailure]
    ) -> Bool {
        guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
            return true
        }

        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: MojoPOSIXSupport.terminationSignal
            )
        } catch {
            if MojoPOSIXSupport.processGroupIsAlive(processID) {
                failures.append(.processGroupTerminationFailed)
            }
        }
        waitForGroupExit(
            processID: processID,
            until: terminationDeadline,
            diagnosticDescriptor: diagnosticDescriptor
        )

        guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
            return true
        }
        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: MojoPOSIXSupport.killSignal
            )
        } catch {
            if MojoPOSIXSupport.processGroupIsAlive(processID) {
                failures.append(.processGroupTerminationFailed)
            }
        }
        waitForGroupExit(
            processID: processID,
            until: forcedCleanupDeadline,
            diagnosticDescriptor: diagnosticDescriptor
        )
        return !MojoPOSIXSupport.processGroupIsAlive(processID)
    }

    private static func waitForGroupExit(
        processID: MojoPOSIXSupport.ProcessID,
        until deadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32?
    ) {
        let clock = ContinuousClock()
        while clock.now < deadline {
            guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
                return
            }
            if let diagnosticDescriptor {
                drainDiagnostics(
                    descriptor: diagnosticDescriptor,
                    deadline: deadline
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    private static func drainDiagnostics(
        descriptor: Int32,
        deadline: ContinuousClock.Instant
    ) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<16 {
            guard ContinuousClock().now < deadline else { return }
            do {
                let result = try buffer.withUnsafeMutableBytes { bytes in
                    try MojoPOSIXWorkerSupport.read(
                        descriptor: descriptor,
                        into: bytes
                    )
                }
                switch result {
                case .bytes:
                    continue
                case .interrupted:
                    continue
                case .wouldBlock, .eof:
                    return
                }
            } catch {
                return
            }
        }
    }
}
