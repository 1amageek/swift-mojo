import Foundation
import MojoPOSIXSupport
import MojoRuntimeWorker
import Synchronization
import Testing

@Suite("Mojo runtime worker terminalizer", .serialized)
struct MojoRuntimeWorkerTerminalizerTests {
    @Test(.timeLimit(.minutes(1)))
    func gracefulNormalExitDoesNotReceiveTerminationSignal() throws {
        let fixture = try makeFixture(
            script: """
            trap 'printf term > "$1"; exit 71' TERM
            printf ready >&3
            while IFS= read -r ignored <&3; do :; done
            exit 0
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .graceful,
            graceful: .milliseconds(500),
            terminationGrace: .milliseconds(150),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.markerURL.path))
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func gracefulNonzeroExitIsRecorded() throws {
        let fixture = try makeFixture(
            script: """
            printf ready >&3
            while IFS= read -r ignored <&3; do :; done
            exit 7
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .graceful,
            graceful: .milliseconds(500),
            terminationGrace: .milliseconds(150),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures == [.processTerminationFailed])
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func hardCleanupAllowsATermCooperativeProcessToExit() throws {
        let fixture = try makeFixture(
            script: """
            printf armed > "$1"
            trap 'printf term >> "$1"; exit 0' TERM
            printf ready >&3
            while :; do :; done
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .hard,
            graceful: .milliseconds(1),
            terminationGrace: .milliseconds(250),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        let marker = try markerContents(fixture)
        #expect(marker == "armedterm")
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func hardCleanupEscalatesATermIgnoringProcessToKill() throws {
        let fixture = try makeFixture(
            script: """
            printf armed > "$1"
            trap 'printf term >> "$1"' TERM
            printf ready >&3
            while :; do :; done
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .hard,
            graceful: .milliseconds(1),
            terminationGrace: .milliseconds(100),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        let marker = try markerContents(fixture)
        #expect(marker == "armedterm")
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func gracefulCleanupEscalatesAfterTheLeaderExits() throws {
        let fixture = try makeFixture(
            script: """
            (
                trap 'printf descendant-term >> "$1"' TERM
                printf armed > "$1"
                while :; do :; done
            ) &
            while [ ! -f "$1" ]; do :; done
            printf ready >&3
            exit 0
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .graceful,
            graceful: .milliseconds(250),
            terminationGrace: .milliseconds(100),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        let marker = try markerContents(fixture)
        #expect(marker == "armeddescendant-term")
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func hardCleanupGivesDescendantsATermGraceAfterLeaderExit() throws {
        let fixture = try makeFixture(
            script: """
            (
                trap 'printf descendant-term >> "$1"; exit 0' TERM
                printf armed > "$1"
                while :; do :; done
            ) &
            while [ ! -f "$1" ]; do :; done
            printf ready >&3
            exit 0
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }

        let failures = terminalize(
            fixture,
            mode: .hard,
            graceful: .milliseconds(1),
            terminationGrace: .milliseconds(250),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        let marker = try markerContents(fixture)
        #expect(marker == "armeddescendant-term")
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func diagnosticFloodCannotStarveCleanupDeadline() throws {
        let fixture = try makeFixture(
            script: """
            trap '' TERM
            printf ready >&3
            while :; do
                printf 0123456789abcdef0123456789abcdef >&2
            done
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }
        let clock = ContinuousClock()
        let startedAt = clock.now

        let failures = terminalize(
            fixture,
            mode: .graceful,
            graceful: .milliseconds(50),
            terminationGrace: .milliseconds(75),
            forcedCleanup: .milliseconds(300)
        )
        terminalizerRan = true

        #expect(failures.isEmpty)
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func unconfirmedLifetimeRetainsPrivateStage() throws {
        let fixture = try makeFixture(
            script: """
            trap '' TERM
            printf ready >&3
            while :; do :; done
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }
        let expiredDeadline = ContinuousClock().now

        let failures = MojoRuntimeWorkerTerminalizer.cleanup(
            process: fixture.process,
            stageRoot: fixture.stageRoot,
            gate: fixture.gate,
            mode: .hard,
            gracefulDeadline: expiredDeadline,
            terminationDeadline: expiredDeadline,
            forcedCleanupDeadline: expiredDeadline
        )
        terminalizerRan = true

        #expect(failures.contains(.processReapFailed))
        #expect(failures.last == .privateStageRetained)
        #expect(FileManager.default.fileExists(atPath: fixture.stageRoot.path))

        reapAfterTermination(fixture.process.processID)
        #expect(!MojoPOSIXSupport.processGroupIsAlive(fixture.process.processID))
        let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: fixture.stageRoot,
                processLifetimeEnded: true
            )
        #expect(stageFailure == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func recordsObservableCleanupFailuresInOperationOrder() throws {
        let fixture = try makeFixture(
            script: """
            printf ready >&3
            while IFS= read -r ignored <&3; do :; done
            exit 0
            """
        )
        var terminalizerRan = false
        defer {
            recover(fixture, descriptorsOwned: !terminalizerRan)
            removeRoot(fixture.rootURL)
        }
        try MojoPOSIXWorkerSupport.closeDescriptor(
            fixture.process.protocolDescriptor
        )
        try MojoPOSIXWorkerSupport.closeDescriptor(
            fixture.process.diagnosticDescriptor
        )

        let failures = terminalize(
            fixture,
            mode: .graceful,
            graceful: .milliseconds(500),
            terminationGrace: .milliseconds(150),
            forcedCleanup: .milliseconds(500)
        )
        terminalizerRan = true

        #expect(
            failures == [
                .transportCloseFailed,
                .diagnosticsCloseFailed,
            ]
        )
        expectLifetimeEnded(fixture)
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func processGroupSignalsAlwaysPrecedeTheExactChildReap() throws {
        let log = TerminalizerProcessControlLog(
            groupStates: [.alive, .alive, .gone]
        )
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in
                log.record("observe")
                return .running
            },
            inspectGroup: { _ in log.nextGroupState() },
            signalGroup: { _, signal in
                log.record("signal:\(signal)")
            },
            reapChild: { _ in
                log.record("reap")
                return 0
            }
        )
        let deadline = ContinuousClock().now

        let outcome = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
            processID: 42,
            mode: .hard,
            gracefulDeadline: deadline,
            terminationDeadline: deadline,
            forcedCleanupDeadline: deadline,
            processControl: control
        )

        #expect(outcome.reaped)
        #expect(outcome.groupTerminationConfirmed)
        #expect(outcome.failures.isEmpty)
        let events = log.events()
        let reapIndex = try #require(events.firstIndex(of: "reap"))
        let terminationIndex = try #require(
            events.firstIndex(
                of: "signal:\(MojoPOSIXSupport.terminationSignal)"
            )
        )
        let killIndex = try #require(
            events.firstIndex(
                of: "signal:\(MojoPOSIXSupport.killSignal)"
            )
        )
        #expect(
            terminationIndex < reapIndex
        )
        #expect(
            killIndex < reapIndex
        )
        #expect(events.last == "reap")
    }

    @Test(.timeLimit(.minutes(1)))
    func outsideOwnerReapForbidsEveryLaterProcessGroupSignal() {
        let log = TerminalizerProcessControlLog(groupStates: [.alive])
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in
                log.record("observe")
                throw MojoPOSIXSupportError.childAlreadyReaped
            },
            inspectGroup: { _ in
                log.record("inspect")
                return .alive
            },
            signalGroup: { _, signal in
                log.record("signal:\(signal)")
            },
            reapChild: { _ in
                log.record("reap")
                return 0
            }
        )
        let deadline = ContinuousClock().now

        let outcome = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
            processID: 42,
            mode: .hard,
            gracefulDeadline: deadline,
            terminationDeadline: deadline,
            forcedCleanupDeadline: deadline,
            processControl: control
        )

        #expect(!outcome.reaped)
        #expect(!outcome.groupTerminationConfirmed)
        #expect(outcome.failures == [.processInspectionFailed])
        #expect(log.events() == ["observe"])
    }

    @Test(.timeLimit(.minutes(1)))
    func indeterminateGroupInspectionCannotAuthorizeStageRemoval() throws {
        let log = TerminalizerProcessControlLog(
            groupStates: [.indeterminate]
        )
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in .running },
            inspectGroup: { _ in log.nextGroupState() },
            signalGroup: { _, signal in
                log.record("signal:\(signal)")
            },
            reapChild: { _ in
                log.record("reap")
                return 0
            }
        )
        let deadline = ContinuousClock().now
        let outcome = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
            processID: 42,
            mode: .hard,
            gracefulDeadline: deadline,
            terminationDeadline: deadline,
            forcedCleanupDeadline: deadline,
            processControl: control
        )

        #expect(outcome.reaped)
        #expect(!outcome.groupTerminationConfirmed)
        #expect(outcome.failures.contains(.processInspectionFailed))

        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stageRoot,
            withIntermediateDirectories: false
        )
        defer { removeRoot(stageRoot) }
        let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded:
                    outcome.reaped && outcome.groupTerminationConfirmed
            )
        #expect(stageFailure == .privateStageRetained)
        #expect(FileManager.default.fileExists(atPath: stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func transientIndeterminateInspectionCannotAuthorizeStageRemoval() throws {
        let log = TerminalizerProcessControlLog(
            groupStates: [.indeterminate, .gone]
        )
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in .running },
            inspectGroup: { _ in log.nextGroupState() },
            signalGroup: { _, signal in
                log.record("signal:\(signal)")
            },
            reapChild: { _ in
                log.record("reap")
                return 0
            }
        )
        let deadline = ContinuousClock().now
        let outcome = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
            processID: 42,
            mode: .hard,
            gracefulDeadline: deadline,
            terminationDeadline: deadline,
            forcedCleanupDeadline: deadline,
            processControl: control
        )

        #expect(outcome.reaped)
        #expect(!outcome.groupTerminationConfirmed)
        #expect(outcome.failures.contains(.processInspectionFailed))

        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stageRoot,
            withIntermediateDirectories: false
        )
        defer { removeRoot(stageRoot) }
        let stageFailure = MojoRuntimeWorkerArtifactAdmission
            .finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded:
                    outcome.reaped && outcome.groupTerminationConfirmed
            )
        #expect(stageFailure == .privateStageRetained)
        #expect(FileManager.default.fileExists(atPath: stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func indeterminateEscalationInspectionRemainsFailClosedAfterGone() {
        let log = TerminalizerProcessControlLog(
            groupStates: [.alive, .indeterminate, .gone]
        )
        let control = MojoRuntimeWorkerProcessControl(
            observeChild: { _ in .running },
            inspectGroup: { _ in log.nextGroupState() },
            signalGroup: { _, signal in
                log.record("signal:\(signal)")
            },
            reapChild: { _ in
                log.record("reap")
                return 0
            }
        )
        let deadline = ContinuousClock().now

        let outcome = MojoRuntimeWorkerTerminalizer.completeProcessLifetime(
            processID: 42,
            mode: .hard,
            gracefulDeadline: deadline,
            terminationDeadline: deadline,
            forcedCleanupDeadline: deadline,
            processControl: control
        )

        #expect(outcome.reaped)
        #expect(!outcome.groupTerminationConfirmed)
        #expect(outcome.failures.contains(.processInspectionFailed))
    }

    private func terminalize(
        _ fixture: TerminalizerFixture,
        mode: MojoRuntimeWorkerTerminalizer.Mode,
        graceful: Duration,
        terminationGrace: Duration,
        forcedCleanup: Duration
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        let clock = ContinuousClock()
        let phaseStart = clock.now
        let gracefulDeadline = phaseStart.advanced(by: graceful)
        let terminationDeadline: ContinuousClock.Instant
        switch mode {
        case .graceful:
            terminationDeadline = gracefulDeadline.advanced(
                by: terminationGrace
            )
        case .hard:
            terminationDeadline = phaseStart.advanced(by: terminationGrace)
        }
        let forcedCleanupDeadline = terminationDeadline.advanced(
            by: forcedCleanup
        )
        return MojoRuntimeWorkerTerminalizer.cleanup(
            process: fixture.process,
            stageRoot: fixture.stageRoot,
            gate: fixture.gate,
            mode: mode,
            gracefulDeadline: gracefulDeadline,
            terminationDeadline: terminationDeadline,
            forcedCleanupDeadline: forcedCleanupDeadline
        )
    }

    private func makeFixture(script: String) throws -> TerminalizerFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swift-mojo-terminalizer-\(UUID().uuidString)",
                isDirectory: true
            )
        let stageRoot = rootURL.appendingPathComponent(
            "stage",
            isDirectory: true
        )
        let markerURL = rootURL.appendingPathComponent("signal-marker")
        try FileManager.default.createDirectory(
            at: stageRoot,
            withIntermediateDirectories: true
        )
        let wakeup = try MojoPOSIXWorkerSupport.createWakeup()
        let gate = MojoRuntimeWorkerCancellationGate(wakeup: wakeup)
        var process: MojoPOSIXWorkerProcess?
        do {
            let spawned = try MojoPOSIXWorkerSupport.spawn(
                executablePath: "/bin/sh",
                arguments: [
                    "-c",
                    script,
                    "terminalizer-fixture",
                    markerURL.path,
                ]
            )
            process = spawned
            try readReady(from: spawned)
            return TerminalizerFixture(
                rootURL: rootURL,
                stageRoot: stageRoot,
                markerURL: markerURL,
                process: spawned,
                gate: gate
            )
        } catch {
            if let process {
                emergencyStop(process)
            }
            let gateFailures = gate.close(
                deadline: ContinuousClock().now.advanced(
                    by: .milliseconds(100)
                )
            )
            if !gateFailures.isEmpty {
                Issue.record(
                    "Failed to close fixture wakeup: \(gateFailures)"
                )
            }
            removeRoot(rootURL)
            throw error
        }
    }

    private func readReady(from process: MojoPOSIXWorkerProcess) throws {
        let expected = Data("ready".utf8)
        var received = Data()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while received.count < expected.count {
            let now = clock.now
            guard now < deadline else {
                throw TerminalizerFixtureError("Readiness deadline expired")
            }
            let pollResult = try MojoPOSIXWorkerSupport.poll(
                protocolDescriptor: process.protocolDescriptor,
                diagnosticDescriptor: process.diagnosticDescriptor,
                interests: [.read],
                timeout: now.duration(to: deadline)
            )
            switch pollResult {
            case .timedOut:
                throw TerminalizerFixtureError("Readiness poll timed out")
            case .interrupted:
                continue
            case .ready(let events):
                if events.contains(.diagnosticReadable) {
                    try drainOneDiagnosticChunk(
                        descriptor: process.diagnosticDescriptor
                    )
                }
                guard events.contains(.protocolReadable) else {
                    if events.contains(.protocolHangup)
                        || events.contains(.protocolError) {
                        throw TerminalizerFixtureError(
                            "Fixture exited before readiness"
                        )
                    }
                    continue
                }
                var buffer = [UInt8](
                    repeating: 0,
                    count: expected.count - received.count
                )
                let result = try buffer.withUnsafeMutableBytes { bytes in
                    try MojoPOSIXWorkerSupport.read(
                        descriptor: process.protocolDescriptor,
                        into: bytes
                    )
                }
                switch result {
                case .bytes(let count):
                    received.append(contentsOf: buffer.prefix(count))
                case .interrupted, .wouldBlock:
                    continue
                case .eof:
                    throw TerminalizerFixtureError(
                        "Fixture reached EOF before readiness"
                    )
                }
            }
        }
        guard received == expected else {
            throw TerminalizerFixtureError("Invalid readiness marker")
        }
    }

    private func drainOneDiagnosticChunk(descriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        _ = try buffer.withUnsafeMutableBytes { bytes in
            try MojoPOSIXWorkerSupport.read(
                descriptor: descriptor,
                into: bytes
            )
        }
    }

    private func markerContents(
        _ fixture: TerminalizerFixture
    ) throws -> String? {
        guard FileManager.default.fileExists(atPath: fixture.markerURL.path)
        else { return nil }
        return String(
            decoding: try Data(contentsOf: fixture.markerURL),
            as: UTF8.self
        )
    }

    private func expectLifetimeEnded(_ fixture: TerminalizerFixture) {
        #expect(
            !MojoPOSIXSupport.processGroupIsAlive(fixture.process.processID)
        )
        do {
            let status = try MojoPOSIXSupport.waitNoHang(
                processID: fixture.process.processID
            )
            Issue.record(
                "Terminalizer did not own the exact child reap: \(String(describing: status))"
            )
        } catch let error as MojoPOSIXSupportError {
            #expect(error == .childAlreadyReaped)
        } catch {
            Issue.record("Failed to inspect terminalized fixture: \(error)")
        }
    }

    private func recover(
        _ fixture: TerminalizerFixture,
        descriptorsOwned: Bool
    ) {
        if MojoPOSIXSupport.processGroupIsAlive(fixture.process.processID) {
            do {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: fixture.process.processID,
                    signal: MojoPOSIXSupport.killSignal
                )
            } catch {
                Issue.record("Failed to kill terminalizer fixture: \(error)")
            }
        }
        reapAfterTermination(fixture.process.processID)
        guard descriptorsOwned else { return }
        for descriptor in [
            fixture.process.protocolDescriptor,
            fixture.process.diagnosticDescriptor,
        ] {
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
            } catch {
                Issue.record("Failed to close fixture descriptor: \(error)")
            }
        }
        let gateFailures = fixture.gate.close(
            deadline: ContinuousClock().now.advanced(
                by: .milliseconds(100)
            )
        )
        if !gateFailures.isEmpty {
            Issue.record("Failed to close fixture wakeup: \(gateFailures)")
        }
    }

    private func emergencyStop(_ process: MojoPOSIXWorkerProcess) {
        if MojoPOSIXSupport.processGroupIsAlive(process.processID) {
            do {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: process.processID,
                    signal: MojoPOSIXSupport.killSignal
                )
            } catch {
                Issue.record("Failed to kill incomplete fixture: \(error)")
            }
        }
        reapAfterTermination(process.processID)
        for descriptor in [
            process.protocolDescriptor,
            process.diagnosticDescriptor,
        ] {
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
            } catch {
                Issue.record("Failed to close incomplete fixture: \(error)")
            }
        }
    }

    private func reapAfterTermination(
        _ processID: MojoPOSIXSupport.ProcessID
    ) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            do {
                if try MojoPOSIXSupport.waitNoHang(processID: processID)
                    != nil {
                    return
                }
            } catch let error as MojoPOSIXSupportError {
                if error == .childAlreadyReaped { return }
                Issue.record("Failed to reap fixture: \(error)")
                return
            } catch {
                Issue.record("Failed to reap fixture: \(error)")
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        Issue.record("Fixture child was not reaped before the deadline")
    }

    private func removeRoot(_ rootURL: URL) {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: rootURL)
        } catch {
            Issue.record("Failed to remove terminalizer fixture: \(error)")
        }
    }
}

private struct TerminalizerFixture {
    let rootURL: URL
    let stageRoot: URL
    let markerURL: URL
    let process: MojoPOSIXWorkerProcess
    let gate: MojoRuntimeWorkerCancellationGate
}

private struct TerminalizerFixtureError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class TerminalizerProcessControlLog: Sendable {
    private struct State: Sendable {
        var events: [String] = []
        var groupStates: [MojoPOSIXProcessGroupState]
        var nextGroupStateIndex = 0
    }

    private let state: Mutex<State>

    init(groupStates: [MojoPOSIXProcessGroupState]) {
        state = Mutex(State(groupStates: groupStates))
    }

    func record(_ event: String) {
        state.withLock { $0.events.append(event) }
    }

    func nextGroupState() -> MojoPOSIXProcessGroupState {
        state.withLock { state in
            state.events.append("inspect")
            guard !state.groupStates.isEmpty else { return .indeterminate }
            let index = min(
                state.nextGroupStateIndex,
                state.groupStates.count - 1
            )
            state.nextGroupStateIndex += 1
            return state.groupStates[index]
        }
    }

    func events() -> [String] {
        state.withLock { $0.events }
    }
}
