import Foundation
import MojoPOSIXSupport

package struct MojoRuntimeWorkerProcessControl: Sendable {
    package typealias ObserveChild = @Sendable (
        MojoPOSIXSupport.ProcessID
    ) throws -> MojoPOSIXChildObservation
    package typealias InspectGroup = @Sendable (
        MojoPOSIXSupport.ProcessID
    ) -> MojoPOSIXProcessGroupState
    package typealias SignalGroup = @Sendable (
        MojoPOSIXSupport.ProcessID,
        Int32
    ) throws -> Void
    package typealias ReapChild = @Sendable (
        MojoPOSIXSupport.ProcessID
    ) throws -> Int32?

    package let observeChild: ObserveChild
    package let inspectGroup: InspectGroup
    package let signalGroup: SignalGroup
    package let reapChild: ReapChild

    package init(
        observeChild: @escaping ObserveChild,
        inspectGroup: @escaping InspectGroup,
        signalGroup: @escaping SignalGroup,
        reapChild: @escaping ReapChild
    ) {
        self.observeChild = observeChild
        self.inspectGroup = inspectGroup
        self.signalGroup = signalGroup
        self.reapChild = reapChild
    }

    package static let live = MojoRuntimeWorkerProcessControl(
        observeChild: { processID in
            try MojoPOSIXSupport.observeChild(processID: processID)
        },
        inspectGroup: { processID in
            MojoPOSIXSupport.processGroupState(processID)
        },
        signalGroup: { processID, signal in
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: signal
            )
        },
        reapChild: { processID in
            try MojoPOSIXSupport.waitNoHang(processID: processID)
        }
    )
}

package struct MojoRuntimeWorkerProcessLifetimeOutcome: Sendable {
    package let reaped: Bool
    package let groupTerminationConfirmed: Bool
    package let failures: [MojoRuntimeWorkerCleanupFailure]
}

package enum MojoRuntimeWorkerTerminalizer {
    package enum Mode: Equatable, Sendable {
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
        forcedCleanupDeadline: ContinuousClock.Instant,
        processControl: MojoRuntimeWorkerProcessControl = .live
    ) -> MojoRuntimeWorkerProcessLifetimeOutcome {
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

        let lifetime = completeProcessLifetime(
            processID: process.processID,
            mode: mode,
            gracefulDeadline: gracefulDeadline,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedCleanupDeadline,
            diagnosticDescriptor: process.diagnosticDescriptor,
            processControl: processControl
        )
        failures.append(contentsOf: lifetime.failures)

        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                process.diagnosticDescriptor
            )
        } catch {
            failures.append(.diagnosticsCloseFailed)
        }

        let processLifetimeEnded =
            lifetime.reaped && lifetime.groupTerminationConfirmed
        if let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded: processLifetimeEnded
            ) {
            failures.append(stageFailure)
        }
        return MojoRuntimeWorkerProcessLifetimeOutcome(
            reaped: lifetime.reaped,
            groupTerminationConfirmed: lifetime.groupTerminationConfirmed,
            failures: failures
        )
    }

    package static func cleanupAdmissionFailure(
        process: MojoPOSIXWorkerProcess,
        stageRoot: URL?,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration,
        processControl: MojoRuntimeWorkerProcessControl = .live
    ) -> MojoRuntimeWorkerProcessLifetimeOutcome {
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
        let lifetime = completeProcessLifetime(
            processID: process.processID,
            mode: .hard,
            gracefulDeadline: clock.now,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedDeadline,
            diagnosticDescriptor: process.diagnosticDescriptor,
            processControl: processControl
        )
        failures.append(contentsOf: lifetime.failures)
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
                processLifetimeEnded:
                    lifetime.reaped && lifetime.groupTerminationConfirmed
            ) {
            failures.append(stageFailure)
        }
        return MojoRuntimeWorkerProcessLifetimeOutcome(
            reaped: lifetime.reaped,
            groupTerminationConfirmed: lifetime.groupTerminationConfirmed,
            failures: failures
        )
    }

    private struct ChildInspection {
        let identityReserved: Bool
        let failures: [MojoRuntimeWorkerCleanupFailure]
    }

    private struct GroupInspection {
        let state: MojoPOSIXProcessGroupState
        let sawIndeterminate: Bool
    }

    package static func completeProcessLifetime(
        processID: MojoPOSIXSupport.ProcessID,
        mode: Mode,
        gracefulDeadline: ContinuousClock.Instant,
        terminationDeadline: ContinuousClock.Instant,
        forcedCleanupDeadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32? = nil,
        processControl: MojoRuntimeWorkerProcessControl = .live
    ) -> MojoRuntimeWorkerProcessLifetimeOutcome {
        let observationDeadline: ContinuousClock.Instant
        switch mode {
        case .graceful:
            observationDeadline = gracefulDeadline
        case .hard:
            observationDeadline = ContinuousClock().now
        }
        let childInspection = inspectChild(
            processID: processID,
            until: observationDeadline,
            diagnosticDescriptor: diagnosticDescriptor,
            requireSuccessfulExit: mode == .graceful,
            processControl: processControl
        )
        var failures = childInspection.failures
        guard childInspection.identityReserved else {
            return MojoRuntimeWorkerProcessLifetimeOutcome(
                reaped: false,
                groupTerminationConfirmed: false,
                failures: failures
            )
        }

        var group = GroupInspection(
            state: processControl.inspectGroup(processID),
            sawIndeterminate: false
        )
        if group.state == .indeterminate {
            group = GroupInspection(
                state: .indeterminate,
                sawIndeterminate: true
            )
        }

        if group.state != .gone {
            signalGroup(
                processID: processID,
                signal: MojoPOSIXSupport.terminationSignal,
                processControl: processControl,
                failures: &failures
            )
            group = waitForGroupExit(
                processID: processID,
                until: terminationDeadline,
                diagnosticDescriptor: diagnosticDescriptor,
                processControl: processControl,
                priorIndeterminate: group.sawIndeterminate
            )
        }

        if group.state != .gone {
            signalGroup(
                processID: processID,
                signal: MojoPOSIXSupport.killSignal,
                processControl: processControl,
                failures: &failures
            )
            group = waitForGroupExit(
                processID: processID,
                until: forcedCleanupDeadline,
                diagnosticDescriptor: diagnosticDescriptor,
                processControl: processControl,
                priorIndeterminate: group.sawIndeterminate
            )
        }

        if group.sawIndeterminate {
            appendUnique(.processInspectionFailed, to: &failures)
        }
        switch group.state {
        case .alive:
            appendUnique(.processGroupTerminationFailed, to: &failures)
        case .indeterminate:
            appendUnique(.processInspectionFailed, to: &failures)
        case .gone:
            break
        }

        // Preserve PID/PGID ownership until a complete observation episode
        // proves disappearance. A later bounded episode can then safely retry.
        guard group.state == .gone, !group.sawIndeterminate else {
            return MojoRuntimeWorkerProcessLifetimeOutcome(
                reaped: false,
                groupTerminationConfirmed: false,
                failures: failures
            )
        }

        // No process-group signal is permitted below this point. Reaping the
        // exact child releases the PID/PGID identity retained by WNOWAIT.
        let reaped = reapChild(
            processID: processID,
            until: forcedCleanupDeadline,
            diagnosticDescriptor: diagnosticDescriptor,
            processControl: processControl,
            failures: &failures
        )
        return MojoRuntimeWorkerProcessLifetimeOutcome(
            reaped: reaped,
            groupTerminationConfirmed:
                group.state == .gone && !group.sawIndeterminate,
            failures: failures
        )
    }

    private static func inspectChild(
        processID: MojoPOSIXSupport.ProcessID,
        until deadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32?,
        requireSuccessfulExit: Bool,
        processControl: MojoRuntimeWorkerProcessControl
    ) -> ChildInspection {
        let clock = ContinuousClock()
        repeat {
            do {
                let observation = try processControl.observeChild(processID)
                if case .exited(let status) = observation {
                    let failures: [MojoRuntimeWorkerCleanupFailure]
                    if requireSuccessfulExit && status != 0 {
                        failures = [.processTerminationFailed]
                    } else {
                        failures = []
                    }
                    return ChildInspection(
                        identityReserved: true,
                        failures: failures
                    )
                }
                guard clock.now < deadline else {
                    return ChildInspection(
                        identityReserved: true,
                        failures: []
                    )
                }
            } catch {
                return ChildInspection(
                    identityReserved: false,
                    failures: [.processInspectionFailed]
                )
            }
            if let diagnosticDescriptor {
                drainDiagnostics(
                    descriptor: diagnosticDescriptor,
                    deadline: deadline
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while clock.now < deadline
        return ChildInspection(
            identityReserved: true,
            failures: []
        )
    }

    private static func signalGroup(
        processID: MojoPOSIXSupport.ProcessID,
        signal: Int32,
        processControl: MojoRuntimeWorkerProcessControl,
        failures: inout [MojoRuntimeWorkerCleanupFailure]
    ) {
        do {
            try processControl.signalGroup(processID, signal)
        } catch {
            appendUnique(.processGroupTerminationFailed, to: &failures)
        }
    }

    private static func waitForGroupExit(
        processID: MojoPOSIXSupport.ProcessID,
        until deadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32?,
        processControl: MojoRuntimeWorkerProcessControl,
        priorIndeterminate: Bool
    ) -> GroupInspection {
        let clock = ContinuousClock()
        var sawIndeterminate = priorIndeterminate
        while true {
            let state = processControl.inspectGroup(processID)
            if state == .indeterminate {
                sawIndeterminate = true
            }
            if state == .gone || clock.now >= deadline {
                return GroupInspection(
                    state: state,
                    sawIndeterminate: sawIndeterminate
                )
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

    private static func reapChild(
        processID: MojoPOSIXSupport.ProcessID,
        until deadline: ContinuousClock.Instant,
        diagnosticDescriptor: Int32?,
        processControl: MojoRuntimeWorkerProcessControl,
        failures: inout [MojoRuntimeWorkerCleanupFailure]
    ) -> Bool {
        let clock = ContinuousClock()
        repeat {
            do {
                if try processControl.reapChild(processID) != nil {
                    return true
                }
            } catch let error as MojoPOSIXSupportError {
                if error == .childAlreadyReaped {
                    appendUnique(.processInspectionFailed, to: &failures)
                } else {
                    appendUnique(.processReapFailed, to: &failures)
                }
                return false
            } catch {
                appendUnique(.processReapFailed, to: &failures)
                return false
            }
            guard clock.now < deadline else {
                appendUnique(.processReapFailed, to: &failures)
                return false
            }
            if let diagnosticDescriptor {
                drainDiagnostics(
                    descriptor: diagnosticDescriptor,
                    deadline: deadline
                )
            }
            Thread.sleep(forTimeInterval: 0.001)
        } while clock.now < deadline
        appendUnique(.processReapFailed, to: &failures)
        return false
    }

    private static func appendUnique(
        _ failure: MojoRuntimeWorkerCleanupFailure,
        to failures: inout [MojoRuntimeWorkerCleanupFailure]
    ) {
        guard !failures.contains(failure) else { return }
        failures.append(failure)
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
