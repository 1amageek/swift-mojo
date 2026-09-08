import Foundation
import Mojo
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Synchronization
import Testing

@Suite("Mojo runtime worker attempt lifecycle")
struct MojoRuntimeWorkerLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func scopedWorkerOrchestratorRunsThePublicSessionLifecycle() async throws {
        let fixture = try ScopedAttemptFixture.make(behavior: .normal)
        defer { fixture.removeSource() }

        let result = try await fixture.withAttempt { session in
            #expect(session.capabilities == fixture.expectedCapabilities)
            let output = try await session.invoke(
                fixture.operation,
                input: [1, 2, 3],
                outputElementCount: 2,
                timeout: .seconds(2)
            )
            #expect(output == [11, 12])
            return 42
        }

        #expect(result == 42)
        let trace = try fixture.traceLines()
        #expect(trace.filter { $0.hasPrefix("create:") }.count == 1)
        #expect(trace.filter { $0.hasPrefix("invoke:") }.count == 1)
        #expect(trace.filter { $0 == "destroy" }.count == 1)
        #expect(trace.filter { $0 == "worker_shutdown" }.count == 1)
        #expect(trace.last == "exit:0")
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func scopedWorkerOrchestratorRethrowsCallerErrorExactly() async throws {
        let fixture = try ScopedAttemptFixture.make(behavior: .normal)
        defer { fixture.removeSource() }
        let sentinel = LifecycleCallerSentinel("caller-sentinel")

        do {
            let _: Void = try await fixture.withAttempt { _ in
                throw sentinel
            }
            Issue.record("The caller failure was not rethrown")
        } catch let error as LifecycleCallerSentinel {
            #expect(error === sentinel)
        } catch {
            Issue.record("Unexpected caller failure: \(error)")
        }

        let trace = try fixture.traceLines()
        #expect(trace.filter { $0 == "destroy" }.count == 1)
        #expect(trace.filter { $0 == "worker_shutdown" }.count == 1)
        #expect(trace.last == "exit:0")
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func scopedWorkerOrchestratorJoinsAnEscapedInFlightTask() async throws {
        let fixture = try ScopedAttemptFixture.make(behavior: .hangOnInvoke)
        defer { fixture.removeSource() }
        let escapedStore = LifecycleEscapedTaskStore()

        do {
            let _: Void = try await fixture.withAttempt { session in
                let escaped = Task {
                    try await session.invoke(
                        fixture.operation,
                        input: [1, 2, 3],
                        outputElementCount: 1,
                        timeout: .seconds(5)
                    )
                }
                escapedStore.store(escaped)
                try await waitForTrace(
                    fixture,
                    containing: "invoke:"
                )
            }
            Issue.record("Scope exit accepted an escaped in-flight call")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .cancellationRequested)
        } catch {
            Issue.record("Unexpected scope-exit error: \(error)")
        }

        guard let escaped = escapedStore.task() else {
            Issue.record("The escaped invocation was not recorded")
            return
        }
        switch await escaped.result {
        case .success:
            Issue.record("The escaped invocation completed successfully")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .cancellationRequested)
        case .failure(let error):
            Issue.record("Unexpected escaped-task error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func scopedWorkerOrchestratorPreservesATypedBodyFailureDuringJoin()
        async throws
    {
        let fixture = try ScopedAttemptFixture.make(behavior: .hangOnInvoke)
        defer { fixture.removeSource() }
        let escapedStore = LifecycleEscapedTaskStore()

        do {
            let _: Void = try await fixture.withAttempt { session in
                let escaped = Task {
                    try await session.invoke(
                        fixture.operation,
                        input: [1, 2, 3],
                        outputElementCount: 1,
                        timeout: .seconds(5)
                    )
                }
                escapedStore.store(escaped)
                try await waitForTrace(fixture, containing: "invoke:")
                throw MojoRuntimeWorkerError.operationInProgress
            }
            Issue.record("The typed body failure was replaced")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .operationInProgress)
        } catch {
            Issue.record("Unexpected typed body failure: \(error)")
        }

        guard let escaped = escapedStore.task() else {
            Issue.record("The escaped invocation was not recorded")
            return
        }
        switch await escaped.result {
        case .success:
            Issue.record("The escaped invocation completed successfully")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .cancellationRequested)
        case .failure(let error):
            Issue.record("Unexpected escaped-task error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func scopeFinalizationJoinsAnEscapedChainedShutdown() async throws {
        let fixture = try ScopedAttemptFixture.make(
            behavior: .pauseAtSessionShutdownAcknowledgement
        )
        defer { fixture.removeSource() }
        let escapedStore = LifecycleEscapedShutdownTaskStore()

        let result = try await fixture.withAttempt { session in
            let escaped = Task {
                try await session.shutdown()
            }
            escapedStore.store(escaped)
            try await waitForTrace(
                fixture,
                containing: "session_shutdown_ack_boundary"
            )
            return 42
        }

        #expect(result == 42)
        guard let escaped = escapedStore.task() else {
            Issue.record("The escaped shutdown was not recorded")
            return
        }
        switch await escaped.result {
        case .success:
            break
        case .failure(let error):
            Issue.record("Unexpected escaped-shutdown error: \(error)")
        }
        let trace = try fixture.traceLines()
        #expect(trace.filter { $0 == "destroy" }.count == 1)
        #expect(trace.filter { $0 == "worker_shutdown" }.count == 1)
        #expect(trace.last == "exit:0")
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringAdmissionStopsBeforeSessionCreation() async throws {
        let fixture = try ScopedAttemptFixture.make(
            behavior: .hangBeforeReady,
            timeouts: MojoRuntimeWorkerTimeouts(
                startup: .seconds(5),
                sessionCreation: .seconds(2),
                gracefulShutdown: .seconds(2),
                terminationGracePeriod: .milliseconds(60),
                forcedCleanup: .seconds(2)
            )
        )
        defer { fixture.removeSource() }
        let attempt = Task {
            try await fixture.withAttempt { _ in
                Issue.record("A cancelled admission exposed a session")
            }
        }
        try await waitForTrace(fixture, containing: "startup_hang")
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        attempt.cancel()

        switch await attempt.result {
        case .success:
            Issue.record("Cancelled admission returned successfully")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .cancellationRequested)
        case .failure(let error):
            Issue.record("Unexpected admission cancellation: \(error)")
        }
        #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
        let trace = try fixture.traceLines()
        #expect(!trace.contains(where: { $0.hasPrefix("create:") }))
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func wakeupCreationFailureRemainsTypedAndReclaimsAdmission() async throws {
        let fixture = try ScopedAttemptFixture.make(behavior: .normal)
        defer { fixture.removeSource() }

        do {
            let _: Void = try await fixture.withAttempt(
                wakeupFactory: {
                    throw LifecycleFixtureFailure.injectedWakeupFailure
                }
            ) { _ in
                Issue.record("A wakeup failure exposed a session")
            }
            Issue.record("A wakeup failure returned successfully")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .wakeupCreationFailed)
        } catch {
            Issue.record("Unexpected wakeup failure: \(error)")
        }

        let trace = try fixture.traceLines()
        #expect(!trace.contains(where: { $0.hasPrefix("create:") }))
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionCreationAndShutdownDeadlinesRemainPhaseTyped() async throws {
        let creation = try ScopedAttemptFixture.make(
            behavior: .delayedSessionCreated,
            timeouts: MojoRuntimeWorkerTimeouts(
                startup: .seconds(2),
                sessionCreation: .milliseconds(50),
                gracefulShutdown: .seconds(1),
                terminationGracePeriod: .milliseconds(60),
                forcedCleanup: .seconds(2)
            )
        )
        defer { creation.removeSource() }
        do {
            let _: Void = try await creation.withAttempt { _ in
                Issue.record("Late session creation exposed a session")
            }
            Issue.record("Late session creation returned successfully")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .sessionCreationTimedOut)
        } catch {
            Issue.record("Unexpected session-creation timeout: \(error)")
        }
        try creation.expectObservedProcessReaped()

        let shutdown = try ScopedAttemptFixture.make(
            behavior: .delayedShutdown,
            timeouts: MojoRuntimeWorkerTimeouts(
                startup: .seconds(2),
                sessionCreation: .seconds(1),
                gracefulShutdown: .milliseconds(50),
                terminationGracePeriod: .milliseconds(60),
                forcedCleanup: .seconds(2)
            )
        )
        defer { shutdown.removeSource() }
        do {
            let _: Void = try await shutdown.withAttempt { _ in }
            Issue.record("Late shutdown returned successfully")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .shutdownTimedOut)
        } catch {
            Issue.record("Unexpected shutdown timeout: \(error)")
        }
        try shutdown.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func mismatchedResultCountIsATypedTerminalResponseFailure() async throws {
        let fixture = try ScopedAttemptFixture.make(behavior: .wrongOutputCount)
        defer { fixture.removeSource() }

        do {
            let _: Void = try await fixture.withAttempt { session in
                _ = try await session.invoke(
                    fixture.operation,
                    input: [1, 2],
                    outputElementCount: 2,
                    timeout: .seconds(2)
                )
            }
            Issue.record("A mismatched result count was accepted")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .responseMismatch)
        } catch {
            Issue.record("Unexpected result-count mismatch: \(error)")
        }
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func scopedWorkerOrchestratorComposesCallerAndCleanupFailures()
        async throws
    {
        let fixture = try ScopedAttemptFixture.make(
            behavior: .nonzeroAfterWorkerShutdown
        )
        defer { fixture.removeSource() }
        let sentinel = LifecycleCallerSentinel("cleanup-sentinel")

        do {
            let _: Void = try await fixture.withAttempt { _ in
                throw sentinel
            }
            Issue.record("Cleanup failure was not composed")
        } catch let error as MojoRuntimeWorkerError {
            guard case .cleanupFailed(let primary, let failures) = error else {
                Issue.record("Unexpected cleanup error: \(error)")
                return
            }
            #expect(
                primary == .caller(
                    typeName: String(
                        reflecting: LifecycleCallerSentinel.self
                    ),
                    description: sentinel.description
                )
            )
            #expect(
                failures == [
                    .processTerminationFailed,
                ]
            )
        } catch {
            Issue.record("Unexpected composed failure: \(error)")
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func fragmentedLifecyclePreservesProvenanceAndDestroysExactlyOnce()
        async throws
    {
        let fixture = try AttemptFixture.make(
            behavior: .normal,
            diagnosticByteCount: 131_072,
            maximumFramePayloadBytes: 2_000_000
        )
        defer { fixture.removeSource() }

        let session = try await fixture.createSession()
        #expect(session.capabilities == fixture.expectedCapabilities)

        let input = [Float](repeating: 3.25, count: 300_000)
        let output = try await fixture.actor.invoke(
            fixture.operation,
            input: input,
            outputElementCount: 3,
            timeout: .seconds(5)
        )
        #expect(output == [11, 12, 13])

        try await fixture.actor.explicitShutdown()

        let trace = try fixture.traceLines()
        #expect(
            trace.contains(
                "create:1:1:1:7:\(fixture.requirements.requiredCapabilities.rawValue)"
            )
        )
        #expect(trace.contains("invoke:2:2:300000:3"))
        #expect(trace.filter { $0 == "destroy" }.count == 1)
        #expect(trace.filter { $0 == "worker_shutdown" }.count == 1)
        #expect(trace.last == "exit:0")
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        expectReaped(fixture.processID)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentCallsAreRejectedWithoutASecondWireMutation() async throws {
        let fixture = try AttemptFixture.make(behavior: .delayedResult)
        defer { fixture.removeSource() }
        _ = try await fixture.createSession()

        let first = Task {
            try await fixture.actor.invoke(
                fixture.operation,
                input: [1, 2],
                outputElementCount: 1,
                timeout: .seconds(3)
            )
        }
        try await waitForInFlight(fixture.actor)

        do {
            _ = try await fixture.actor.invoke(
                fixture.operation,
                input: [3, 4],
                outputElementCount: 1,
                timeout: .seconds(1)
            )
            Issue.record("A second invoke was accepted while one was active")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .operationInProgress)
        } catch {
            Issue.record("Unexpected second-invoke error: \(error)")
        }

        do {
            try await fixture.actor.explicitShutdown()
            Issue.record("Shutdown mutated an attempt with an active invoke")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .operationInProgress)
        } catch {
            Issue.record("Unexpected busy-shutdown error: \(error)")
        }

        let busyTrace = try fixture.traceLines()
        #expect(busyTrace.filter { $0.hasPrefix("invoke:") }.count == 1)
        #expect(!busyTrace.contains("destroy"))
        #expect(!busyTrace.contains("worker_shutdown"))

        let firstOutput = try await first.value
        #expect(firstOutput == [11])
        try await fixture.actor.explicitShutdown()

        let finalTrace = try fixture.traceLines()
        #expect(finalTrace.filter { $0.hasPrefix("invoke:") }.count == 1)
        #expect(finalTrace.filter { $0 == "destroy" }.count == 1)
        #expect(finalTrace.filter { $0 == "worker_shutdown" }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBetweenCallsUsesGracefulAcknowledgements() async throws {
        let fixture = try AttemptFixture.make(behavior: .normal)
        defer { fixture.removeSource() }
        _ = try await fixture.createSession()

        fixture.gate.cancelScope()
        let cleanupError = await fixture.actor.finishAttempt()

        #expect(cleanupError == nil)
        let trace = try fixture.traceLines()
        #expect(trace.filter { $0 == "destroy" }.count == 1)
        #expect(trace.filter { $0 == "worker_shutdown" }.count == 1)
        #expect(trace.last == "exit:0")
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        expectReaped(fixture.processID)
    }

    @Test(.timeLimit(.minutes(1)))
    func inFlightCancellationHardCleansAndANewAttemptRemainsUsable()
        async throws
    {
        let cancelled = try AttemptFixture.make(behavior: .hangOnInvoke)
        defer { cancelled.removeSource() }
        _ = try await cancelled.createSession()

        let invocation = Task {
            try await cancelled.actor.invoke(
                cancelled.operation,
                input: [1, 2, 3],
                outputElementCount: 1,
                timeout: .seconds(5)
            )
        }
        try await waitForInFlight(cancelled.actor)
        try await waitForTrace(cancelled, containing: "invoke:")
        invocation.cancel()

        switch await invocation.result {
        case .success:
            Issue.record("A cancelled in-flight result was accepted")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .cancellationRequested)
        case .failure(let error):
            Issue.record("Unexpected cancellation error: \(error)")
        }
        #expect(
            !FileManager.default.fileExists(atPath: cancelled.stageRoot.path)
        )
        expectReaped(cancelled.processID)
        let cancelledTrace = try cancelled.traceLines()
        #expect(!cancelledTrace.contains("destroy"))
        #expect(!cancelledTrace.contains("worker_shutdown"))

        let fresh = try AttemptFixture.make(behavior: .normal)
        defer { fresh.removeSource() }
        _ = try await fresh.createSession()
        let output = try await fresh.actor.invoke(
            fresh.operation,
            input: [9],
            outputElementCount: 1,
            timeout: .seconds(2)
        )
        #expect(output == [11])
        try await fresh.actor.explicitShutdown()
        let freshTrace = try fresh.traceLines()
        #expect(freshTrace.filter { $0.hasPrefix("invoke:") }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func resourceBearingAttemptCancellationRemovesTheCompletePrivateStage()
        async throws
    {
        let fixture = try ScopedAttemptFixture.make(behavior: .hangOnInvoke)
        defer { fixture.removeSource() }
        let firstURL = fixture.sourceRoot.appendingPathComponent("first-resource")
        let secondURL = fixture.sourceRoot.appendingPathComponent("second-resource")
        try Data("abc".utf8).write(to: firstURL)
        try Data("def".utf8).write(to: secondURL)
        let firstDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let secondDigest = "cb8379ac2098aa165029e3938a51da0bcecfc008fd6795f401178647f96c5b34"
        let resources = try MojoRuntimeWorkerInputResources(
            resources: [
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("first"),
                    fileURL: firstURL,
                    expectedByteCount: 3,
                    expectedSHA256: firstDigest
                ),
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("second"),
                    fileURL: secondURL,
                    expectedByteCount: 3,
                    expectedSHA256: secondDigest
                ),
            ],
            limits: try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 2, maximumAggregateByteCount: 6
            )
        )

        let invocation = Task {
            try await fixture.withAttempt(inputResources: resources) { session in
                try await session.invoke(
                    fixture.operation,
                    input: [1, 2, 3],
                    outputElementCount: 1,
                    timeout: .seconds(5)
                )
            }
        }
        try await waitForTrace(fixture, containing: "invoke:")
        invocation.cancel()

        switch await invocation.result {
        case .success:
            Issue.record("A cancelled resource-bearing invocation succeeded")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .cancellationRequested)
        case .failure(let error):
            Issue.record("Unexpected resource-bearing cancellation error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        try fixture.expectObservedProcessReaped()
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutRejectsAPartialResultAndReclaimsTheWorker() async throws {
        let fixture = try AttemptFixture.make(behavior: .partialResult)
        defer { fixture.removeSource() }
        _ = try await fixture.createSession()

        do {
            _ = try await fixture.actor.invoke(
                fixture.operation,
                input: [5, 6],
                outputElementCount: 2,
                timeout: .milliseconds(120)
            )
            Issue.record("A partial result was accepted as complete")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .invocationTimedOut)
        } catch {
            Issue.record("Unexpected partial-result error: \(error)")
        }

        let trace = try fixture.traceLines()
        #expect(trace.contains("partial_result"))
        #expect(!trace.contains("destroy"))
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        expectReaped(fixture.processID)
    }

    @Test(.timeLimit(.minutes(1)))
    func lateFailedInvocationResponsesExpireAndCannotReuseWorker()
        async throws
    {
        for behavior in [
            LifecycleFixtureBehavior.delayedInvocationFailure,
            LifecycleFixtureBehavior.delayedRemoteFailure,
        ] {
            let fixture = try AttemptFixture.make(behavior: behavior)
            defer { fixture.removeSource() }
            _ = try await fixture.createSession()

            var observedError: MojoRuntimeWorkerError?
            do {
                _ = try await fixture.actor.invoke(
                    fixture.operation,
                    input: [1],
                    outputElementCount: 1,
                    timeout: .milliseconds(50)
                )
                Issue.record("A late failed response completed successfully")
            } catch let error as MojoRuntimeWorkerError {
                observedError = error
            } catch {
                Issue.record("Unexpected late-response error: \(error)")
            }
            #expect(observedError == .invocationTimedOut)

            do {
                _ = try await fixture.actor.invoke(
                    fixture.operation,
                    input: [2],
                    outputElementCount: 1,
                    timeout: .seconds(1)
                )
                Issue.record(
                    "A worker was reused after a late failed response"
                )
            } catch let error as MojoRuntimeWorkerError {
                #expect(error == .attemptClosed)
            } catch {
                Issue.record("Unexpected terminal-attempt error: \(error)")
            }

            _ = await fixture.actor.finishAttempt()
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.stageRoot.path
                )
            )
            expectReaped(fixture.processID)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func crashEOFAndRemoteFailureStayTypedAndTerminal() async throws {
        let crashed = try AttemptFixture.make(behavior: .crashOnInvoke)
        defer { crashed.removeSource() }
        _ = try await crashed.createSession()
        do {
            _ = try await crashed.actor.invoke(
                crashed.operation,
                input: [1],
                outputElementCount: 1,
                timeout: .seconds(2)
            )
            Issue.record("A crashed worker produced a successful invocation")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .workerExited)
        } catch {
            Issue.record("Unexpected crash error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: crashed.stageRoot.path))
        expectReaped(crashed.processID)

        let failed = try AttemptFixture.make(behavior: .remoteFailure)
        defer { failed.removeSource() }
        _ = try await failed.createSession()
        do {
            _ = try await failed.actor.invoke(
                failed.operation,
                input: [1],
                outputElementCount: 1,
                timeout: .seconds(2)
            )
            Issue.record("A terminal worker failure was accepted as a result")
        } catch let error as MojoRuntimeWorkerError {
            #expect(
                error == .remoteFailure(
                    code: .invocationFailed,
                    diagnostic: "fixture-remote-failure"
                )
            )
        } catch {
            Issue.record("Unexpected remote failure error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: failed.stageRoot.path))
        expectReaped(failed.processID)
    }

    @Test(.timeLimit(.minutes(1)))
    func escapedTaskCannotUseAnAttemptAfterScopeFinalization() async throws {
        let fixture = try AttemptFixture.make(behavior: .normal)
        defer { fixture.removeSource() }
        _ = try await fixture.createSession()
        let latch = LifecycleTestLatch()
        let escaped = Task {
            await latch.wait()
            return try await fixture.actor.invoke(
                fixture.operation,
                input: [1],
                outputElementCount: 1,
                timeout: .seconds(1)
            )
        }

        let cleanupError = await fixture.actor.finishAttempt()
        #expect(cleanupError == nil)
        await latch.release()

        switch await escaped.result {
        case .success:
            Issue.record("An escaped task used a finalized attempt")
        case .failure(let error as MojoRuntimeWorkerError):
            #expect(error == .attemptClosed)
        case .failure(let error):
            Issue.record("Unexpected escaped-task error: \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.stageRoot.path))
        expectReaped(fixture.processID)
    }
}

private enum LifecycleFixtureBehavior: String {
    case normal
    case delayedResult
    case hangOnInvoke
    case partialResult
    case crashOnInvoke
    case remoteFailure
    case delayedInvocationFailure
    case delayedRemoteFailure
    case hangAfterWorkerShutdown
    case nonzeroAfterWorkerShutdown
    case hangBeforeReady
    case delayedSessionCreated
    case delayedShutdown
    case wrongOutputCount
    case pauseAtSessionShutdownAcknowledgement
}

private struct AttemptFixture: Sendable {
    let sourceRoot: URL
    let traceURL: URL
    let stageRoot: URL
    let processID: MojoPOSIXSupport.ProcessID
    let actor: MojoRuntimeWorkerAttemptActor
    let gate: MojoRuntimeWorkerCancellationGate
    let factory: MojoRuntimeWorkerSessionFactory
    let operation: MojoRuntimeWorkerFloat32Operation
    let requirements: MojoSessionRequirements
    let expectedCapabilities: MojoSessionCapabilities

    static func make(
        behavior: LifecycleFixtureBehavior,
        diagnosticByteCount: Int = 0,
        maximumFramePayloadBytes: UInt64 = 65_536
    ) throws -> Self {
        let fileManager = FileManager.default
        let sourceRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-lifecycle-source-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleURL = sourceRoot.appendingPathComponent(
            "fixture.bundle",
            isDirectory: true
        )
        let binURL = bundleURL.appendingPathComponent("bin", isDirectory: true)
        let traceURL = sourceRoot.appendingPathComponent("trace.log")
        do {
            try fileManager.createDirectory(
                at: binURL,
                withIntermediateDirectories: true
            )
            try Data().write(to: traceURL)

            let verification = MojoRuntimeWorkerTestFixture.verification(
                bundleURL: bundleURL,
                maximumFramePayloadBytes: maximumFramePayloadBytes
            )
            let readyData = try MojoRuntimeWorkerTestFixture.readyFrameData(
                for: verification
            )
            let interpreter = try pythonInterpreter(fileManager: fileManager)
            let script = workerScript(
                interpreter: interpreter,
                readyData: readyData,
                traceURL: traceURL,
                behavior: behavior,
                diagnosticByteCount: diagnosticByteCount
            )
            let workerURL = binURL.appendingPathComponent("worker")
            let scriptData = Data(script.utf8)
            try scriptData.write(to: workerURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workerURL.path
            )

            // W2 integrity and production manifest verification are owned by
            // the artifact-admission suite. This fixture injects the immutable
            // projection only to exercise W3's real stage/spawn/protocol path.
            let admission = MojoRuntimeWorkerArtifactAdmission(
                fileManager: fileManager,
                verify: { stagedBundleURL in
                    let stagedWorker = stagedBundleURL
                        .appendingPathComponent("bin/worker")
                    guard try Data(contentsOf: stagedWorker) == scriptData else {
                        throw LifecycleFixtureFailure.stagedWorkerChanged
                    }
                    return MojoRuntimeWorkerTestFixture.rebased(
                        verification,
                        to: stagedBundleURL
                    )
                },
                spawn: { executablePath, arguments, environment in
                    try MojoPOSIXWorkerSupport.spawn(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: environment
                    )
                },
                readStartupAtDeadline: { process, staged, deadline in
                    try MojoRuntimeWorkerStartupReader.readReady(
                        from: process,
                        verification: staged,
                        deadline: deadline
                    )
                }
            )
            let timeouts = try MojoRuntimeWorkerTimeouts(
                startup: .seconds(3),
                sessionCreation: .seconds(2),
                gracefulShutdown: .seconds(2),
                terminationGracePeriod: .milliseconds(60),
                forcedCleanup: .seconds(2)
            )
            let clock = ContinuousClock()
            let admitted = try admission.admit(
                verification: verification,
                startupDeadline: clock.now.advanced(by: timeouts.startup),
                terminationGracePeriod: timeouts.terminationGracePeriod,
                forcedCleanup: timeouts.forcedCleanup
            )
            let wakeup = try MojoPOSIXWorkerSupport.createWakeup()
            let gate = MojoRuntimeWorkerCancellationGate(wakeup: wakeup)
            let requirements = MojoSessionRequirements(
                device: .accelerator,
                ordinal: 7,
                requiredCapabilities: [.deviceMemory, .float32]
            )
            let expectedCapabilities = MojoSessionCapabilities(
                device: .accelerator,
                ordinal: 7,
                availableCapabilities: [
                    .synchronousInvocation,
                    .deviceMemory,
                    .float32,
                ]
            )
            let worker = try MojoRuntimeWorker(verification: verification)
            let factory = try worker.sessionFactory(
                for: verification.bindings[0]
            )
            let operation = try worker.float32Operation(
                for: verification.bindings[1]
            )
            let actor = MojoRuntimeWorkerAttemptActor(
                admitted: admitted,
                gate: gate,
                factoryBinding: verification.bindings[0],
                requirements: requirements,
                timeouts: timeouts
            )
            return Self(
                sourceRoot: sourceRoot,
                traceURL: traceURL,
                stageRoot: admitted.stage.rootURL,
                processID: admitted.process.processID,
                actor: actor,
                gate: gate,
                factory: factory,
                operation: operation,
                requirements: requirements,
                expectedCapabilities: expectedCapabilities
            )
        } catch {
            do {
                if fileManager.fileExists(atPath: sourceRoot.path) {
                    try fileManager.removeItem(at: sourceRoot)
                }
            } catch let cleanupError {
                Issue.record("Failed to remove failed fixture: \(cleanupError)")
            }
            throw error
        }
    }

    func createSession() async throws -> MojoRuntimeWorkerSessionState {
        let clock = ContinuousClock()
        return try await actor.createSession(
            factory: factory,
            deadline: clock.now.advanced(by: .seconds(2))
        )
    }

    func traceLines() throws -> [String] {
        let text = String(decoding: try Data(contentsOf: traceURL), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    func removeSource() {
        do {
            if FileManager.default.fileExists(atPath: sourceRoot.path) {
                try FileManager.default.removeItem(at: sourceRoot)
            }
        } catch {
            Issue.record("Failed to remove lifecycle fixture: \(error)")
        }
    }

    fileprivate static func pythonInterpreter(
        fileManager: FileManager
    ) throws -> String {
        for candidate in [
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
        ] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        throw LifecycleFixtureFailure.pythonUnavailable
    }

    fileprivate static func workerScript(
        interpreter: String,
        readyData: Data,
        traceURL: URL,
        behavior: LifecycleFixtureBehavior,
        diagnosticByteCount: Int
    ) -> String {
        let tracePath = Data(traceURL.path.utf8).base64EncodedString()
        let readyHex = readyData.map { String(format: "%02x", $0) }.joined()
        return #"""
        #!\#(interpreter)
        import base64
        import os
        import signal
        import struct
        import sys
        import time

        FD = 3
        HEADER = struct.Struct("<4sHHQQQ")
        TRACE_PATH = base64.b64decode("\#(tracePath)").decode("utf-8")
        READY = bytes.fromhex("\#(readyHex)")
        BEHAVIOR = "\#(behavior.rawValue)"
        DIAGNOSTIC_BYTES = \#(diagnosticByteCount)
        EXPECTED_CREATE = (1, 1, 1, 7, 20)
        AVAILABLE_CAPABILITIES = 21

        if BEHAVIOR in ("hangOnInvoke", "partialResult", "hangAfterWorkerShutdown"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)

        def record(value):
            descriptor = os.open(
                TRACE_PATH,
                os.O_WRONLY | os.O_CREAT | os.O_APPEND,
                0o600,
            )
            try:
                os.write(descriptor, (value + "\n").encode("utf-8"))
            finally:
                os.close(descriptor)

        def read_exact(byte_count):
            chunks = []
            remaining = byte_count
            while remaining:
                chunk = os.read(FD, min(257, remaining))
                if not chunk:
                    raise EOFError()
                chunks.append(chunk)
                remaining -= len(chunk)
            return b"".join(chunks)

        def write_all(data):
            offset = 0
            while offset < len(data):
                count = os.write(FD, data[offset:])
                if count <= 0:
                    raise BrokenPipeError()
                offset += count

        def write_fragmented(data):
            sizes = (1, 2, 5, 3, 8, 13)
            offset = 0
            index = 0
            while offset < len(data):
                end = min(offset + sizes[index % len(sizes)], len(data))
                write_all(data[offset:end])
                offset = end
                index += 1
                time.sleep(0.0005)

        def frame(kind, request_id, payload=b""):
            return HEADER.pack(b"SMW1", 1, kind, request_id, len(payload), 0) + payload

        def send(kind, request_id, payload=b""):
            write_fragmented(frame(kind, request_id, payload))

        def fail(request_id, code, diagnostic):
            encoded = diagnostic.encode("utf-8")
            send(10, request_id, struct.pack("<HHI", code, 0, len(encoded)) + encoded)

        def write_diagnostics(byte_count):
            remaining = byte_count
            chunk = b"d" * 4096
            while remaining:
                current = chunk[:min(len(chunk), remaining)]
                offset = 0
                while offset < len(current):
                    offset += os.write(2, current[offset:])
                remaining -= len(current)

        if BEHAVIOR == "hangBeforeReady":
            record("startup_hang")
            while True:
                time.sleep(1)

        write_fragmented(READY)
        record("ready")
        last_request_id = 0
        session_live = False
        invoke_count = 0

        while True:
            try:
                header = read_exact(HEADER.size)
            except EOFError:
                sys.exit(0)
            magic, version, kind, request_id, payload_length, reserved = HEADER.unpack(header)
            if magic != b"SMW1" or version != 1 or reserved != 0:
                sys.exit(90)
            payload = read_exact(payload_length)
            if request_id <= last_request_id:
                fail(request_id, 2, "non-monotonic-request")
                sys.exit(91)
            last_request_id = request_id

            if kind == 2:
                if len(payload) != 28:
                    fail(request_id, 1, "invalid-create-size")
                    sys.exit(92)
                values = struct.unpack("<QIIIQ", payload)
                record("create:%d:%d:%d:%d:%d" % values)
                if values != EXPECTED_CREATE:
                    fail(request_id, 3, "create-provenance-mismatch")
                    sys.exit(93)
                if BEHAVIOR == "delayedSessionCreated":
                    time.sleep(0.2)
                session_live = True
                response = struct.pack("<iIIIQ", 0, 1, 1, 7, AVAILABLE_CAPABILITIES)
                send(3, request_id, response)
            elif kind == 4:
                if not session_live or len(payload) < 24:
                    fail(request_id, 4, "session-unavailable")
                    sys.exit(94)
                binding_id, input_count, output_count = struct.unpack("<QQQ", payload[:24])
                if binding_id != 2 or len(payload) != 24 + input_count * 4:
                    fail(request_id, 3, "invoke-provenance-mismatch")
                    sys.exit(95)
                invoke_count += 1
                record(
                    "invoke:%d:%d:%d:%d" % (
                        request_id,
                        binding_id,
                        input_count,
                        output_count,
                    )
                )
                if DIAGNOSTIC_BYTES:
                    write_diagnostics(DIAGNOSTIC_BYTES)
                if BEHAVIOR == "delayedResult":
                    time.sleep(0.25)
                elif BEHAVIOR == "hangOnInvoke":
                    while True:
                        time.sleep(1)
                elif BEHAVIOR == "crashOnInvoke":
                    os._exit(17)
                elif BEHAVIOR == "remoteFailure":
                    fail(request_id, 5, "fixture-remote-failure")
                    while True:
                        time.sleep(1)
                elif BEHAVIOR == "delayedRemoteFailure":
                    time.sleep(0.2)
                    fail(request_id, 5, "fixture-remote-failure")
                    while True:
                        time.sleep(1)
                elif BEHAVIOR == "delayedInvocationFailure":
                    time.sleep(0.2)
                    send(5, request_id, struct.pack("<iQ", 17, 0))
                    continue
                result_count = output_count
                if BEHAVIOR == "wrongOutputCount":
                    result_count += 1
                values = [11.0 + float(index) for index in range(result_count)]
                body = struct.pack("<" + "f" * len(values), *values)
                prefix = struct.pack("<iQ", 0, result_count)
                if BEHAVIOR == "partialResult":
                    packet = frame(5, request_id, prefix + body)
                    write_all(packet[:HEADER.size + len(prefix) + 2])
                    record("partial_result")
                    while True:
                        time.sleep(1)
                send(5, request_id, prefix + body)
            elif kind == 6:
                if payload or not session_live:
                    fail(request_id, 6, "invalid-session-shutdown")
                    sys.exit(96)
                if BEHAVIOR == "delayedShutdown":
                    time.sleep(0.2)
                session_live = False
                record("destroy")
                if BEHAVIOR == "pauseAtSessionShutdownAcknowledgement":
                    record("session_shutdown_ack_boundary")
                send(7, request_id)
                if BEHAVIOR == "pauseAtSessionShutdownAcknowledgement":
                    time.sleep(0.2)
            elif kind == 8:
                if payload or session_live:
                    fail(request_id, 6, "invalid-worker-shutdown")
                    sys.exit(97)
                record("worker_shutdown")
                send(9, request_id)
                if BEHAVIOR == "hangAfterWorkerShutdown":
                    while True:
                        time.sleep(1)
                if BEHAVIOR == "nonzeroAfterWorkerShutdown":
                    record("exit:73")
                    sys.exit(73)
                record("exit:0")
                sys.exit(0)
            else:
                fail(request_id, 1, "unexpected-kind")
                sys.exit(98)
        """#
    }
}

private struct ScopedAttemptFixture: Sendable {
    let sourceRoot: URL
    let traceURL: URL
    let stageRoot: URL
    let verification: MojoRuntimeWorkerBundleVerification
    let worker: MojoRuntimeWorker
    let factory: MojoRuntimeWorkerSessionFactory
    let operation: MojoRuntimeWorkerFloat32Operation
    let requirements: MojoSessionRequirements
    let expectedCapabilities: MojoSessionCapabilities
    let timeouts: MojoRuntimeWorkerTimeouts
    let scriptData: Data
    let observation: LifecycleProcessObservation

    static func make(
        behavior: LifecycleFixtureBehavior,
        timeouts: MojoRuntimeWorkerTimeouts? = nil
    ) throws -> Self {
        let fileManager = FileManager.default
        let sourceRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-scoped-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundleURL = sourceRoot.appendingPathComponent(
            "fixture.bundle",
            isDirectory: true
        )
        let binURL = bundleURL.appendingPathComponent("bin", isDirectory: true)
        let traceURL = sourceRoot.appendingPathComponent("trace.log")
        do {
            try fileManager.createDirectory(
                at: binURL,
                withIntermediateDirectories: true
            )
            try Data().write(to: traceURL)
            let verification = MojoRuntimeWorkerTestFixture.verification(
                bundleURL: bundleURL
            )
            let readyData = try MojoRuntimeWorkerTestFixture.readyFrameData(
                for: verification
            )
            let interpreter = try AttemptFixture.pythonInterpreter(
                fileManager: fileManager
            )
            let script = AttemptFixture.workerScript(
                interpreter: interpreter,
                readyData: readyData,
                traceURL: traceURL,
                behavior: behavior,
                diagnosticByteCount: 0
            )
            let scriptData = Data(script.utf8)
            let workerURL = binURL.appendingPathComponent("worker")
            try scriptData.write(to: workerURL)
            try fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: workerURL.path
            )

            let worker = try MojoRuntimeWorker(verification: verification)
            let factory = try worker.sessionFactory(
                for: verification.bindings[0]
            )
            let operation = try worker.float32Operation(
                for: verification.bindings[1]
            )
            let requirements = MojoSessionRequirements(
                device: .accelerator,
                ordinal: 7,
                requiredCapabilities: [.deviceMemory, .float32]
            )
            let expectedCapabilities = MojoSessionCapabilities(
                device: .accelerator,
                ordinal: 7,
                availableCapabilities: [
                    .synchronousInvocation,
                    .deviceMemory,
                    .float32,
                ]
            )
            let resolvedTimeouts: MojoRuntimeWorkerTimeouts
            if let timeouts {
                resolvedTimeouts = timeouts
            } else {
                resolvedTimeouts = try MojoRuntimeWorkerTimeouts(
                    startup: .seconds(3),
                    sessionCreation: .seconds(2),
                    gracefulShutdown: .seconds(2),
                    terminationGracePeriod: .milliseconds(60),
                    forcedCleanup: .seconds(2)
                )
            }
            return Self(
                sourceRoot: sourceRoot,
                traceURL: traceURL,
                stageRoot: sourceRoot.appendingPathComponent(
                    "private-stage",
                    isDirectory: true
                ),
                verification: verification,
                worker: worker,
                factory: factory,
                operation: operation,
                requirements: requirements,
                expectedCapabilities: expectedCapabilities,
                timeouts: resolvedTimeouts,
                scriptData: scriptData,
                observation: LifecycleProcessObservation()
            )
        } catch {
            if fileManager.fileExists(atPath: sourceRoot.path) {
                try fileManager.removeItem(at: sourceRoot)
            }
            throw error
        }
    }

    func withAttempt<Result: Sendable>(
        inputResources: MojoRuntimeWorkerInputResources? = nil,
        wakeupFactory: @escaping @Sendable () throws
            -> MojoPOSIXWorkerWakeup = {
                try MojoPOSIXWorkerSupport.createWakeup()
            },
        _ body: @Sendable (
            MojoRuntimeWorkerSession
        ) async throws -> Result
    ) async throws -> Result {
        let verification = self.verification
        let scriptData = self.scriptData
        let stageRoot = self.stageRoot
        let observation = self.observation
        return try await worker.withAttempt(
            sessionFactory: factory,
            requirements: requirements,
            inputResources: inputResources,
            timeouts: timeouts,
            admissionFactory: {
                let fileManager = FileManager.default
                return MojoRuntimeWorkerArtifactAdmission(
                    fileManager: fileManager,
                    verify: { stagedBundleURL in
                        let stagedWorker = stagedBundleURL
                            .appendingPathComponent("bin/worker")
                        guard try Data(contentsOf: stagedWorker) == scriptData
                        else {
                            throw LifecycleFixtureFailure.stagedWorkerChanged
                        }
                        return MojoRuntimeWorkerTestFixture.rebased(
                            verification,
                            to: stagedBundleURL
                        )
                    },
                    spawn: { executablePath, arguments, environment in
                        let process = try MojoPOSIXWorkerSupport.spawn(
                            executablePath: executablePath,
                            arguments: arguments,
                            environment: environment
                        )
                        observation.record(process)
                        return process
                    },
                    readStartupAtDeadline: { process, staged, deadline in
                        try MojoRuntimeWorkerStartupReader.readReady(
                            from: process,
                            verification: staged,
                            deadline: deadline
                        )
                    },
                    makeStageRoot: { stageRoot }
                )
            },
            wakeupFactory: wakeupFactory,
            body
        )
    }

    func traceLines() throws -> [String] {
        let text = String(decoding: try Data(contentsOf: traceURL), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }

    func expectObservedProcessReaped() throws {
        guard let process = observation.process() else {
            throw LifecycleFixtureFailure.processWasNotObserved
        }
        expectReaped(process.processID)
    }

    func removeSource() {
        if let process = observation.process() {
            recoverProcessIfNeeded(process.processID)
        }
        if FileManager.default.fileExists(atPath: stageRoot.path),
           let failure = MojoRuntimeWorkerArtifactAdmission
               .finalizePrivateStage(
                   at: stageRoot,
                   processLifetimeEnded: true
               ) {
            Issue.record("Failed to recover retained stage: \(failure)")
        }
        do {
            if FileManager.default.fileExists(atPath: sourceRoot.path) {
                try FileManager.default.removeItem(at: sourceRoot)
            }
        } catch {
            Issue.record("Failed to remove scoped fixture: \(error)")
        }
    }
}

private final class LifecycleProcessObservation: Sendable {
    private let storage = Mutex<MojoPOSIXWorkerProcess?>(nil)

    func record(_ process: MojoPOSIXWorkerProcess) {
        storage.withLock { $0 = process }
    }

    func process() -> MojoPOSIXWorkerProcess? {
        storage.withLock { $0 }
    }
}

private final class LifecycleCallerSentinel:
    Error, Sendable, CustomStringConvertible
{
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private typealias LifecycleInvocationTask = Task<[Float], any Error>

private final class LifecycleEscapedTaskStore: Sendable {
    private let storage = Mutex<LifecycleInvocationTask?>(nil)

    func store(_ task: LifecycleInvocationTask) {
        storage.withLock { $0 = task }
    }

    func task() -> LifecycleInvocationTask? {
        storage.withLock { $0 }
    }
}

private typealias LifecycleShutdownTask = Task<Void, any Error>

private final class LifecycleEscapedShutdownTaskStore: Sendable {
    private let storage = Mutex<LifecycleShutdownTask?>(nil)

    func store(_ task: LifecycleShutdownTask) {
        storage.withLock { $0 = task }
    }

    func task() -> LifecycleShutdownTask? {
        storage.withLock { $0 }
    }
}

private actor LifecycleTestLatch {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in pending {
            continuation.resume()
        }
    }
}

private enum LifecycleFixtureFailure: Error {
    case pythonUnavailable
    case stagedWorkerChanged
    case inFlightDidNotStart
    case traceDidNotAppear
    case processWasNotObserved
    case injectedWakeupFailure
}

private func waitForInFlight(
    _ actor: MojoRuntimeWorkerAttemptActor
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if await actor.hasInFlightExchange() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw LifecycleFixtureFailure.inFlightDidNotStart
}

private func waitForTrace(
    _ fixture: AttemptFixture,
    containing expected: String
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if try fixture.traceLines().contains(where: { $0.contains(expected) }) {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw LifecycleFixtureFailure.traceDidNotAppear
}

private func waitForTrace(
    _ fixture: ScopedAttemptFixture,
    containing expected: String
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        if try fixture.traceLines().contains(where: { $0.contains(expected) }) {
            return
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw LifecycleFixtureFailure.traceDidNotAppear
}

private func recoverProcessIfNeeded(
    _ processID: MojoPOSIXSupport.ProcessID
) {
    do {
        if try MojoPOSIXSupport.waitNoHang(processID: processID) != nil {
            return
        }
    } catch let error as MojoPOSIXSupportError {
        if error == .childAlreadyReaped { return }
        Issue.record("Failed to inspect retained fixture: \(error)")
    } catch {
        Issue.record("Failed to inspect retained fixture: \(error)")
    }
    if MojoPOSIXSupport.processGroupIsAlive(processID) {
        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: MojoPOSIXSupport.killSignal
            )
        } catch {
            // The production terminalizer may already have delivered KILL;
            // on Darwin the group can become an unsignalable zombie between
            // the preceding inspection and this recovery signal. The reap
            // barrier below is the authoritative lifetime check.
        }
    }
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        do {
            if try MojoPOSIXSupport.waitNoHang(processID: processID) != nil {
                return
            }
        } catch let error as MojoPOSIXSupportError {
            if error == .childAlreadyReaped { return }
            Issue.record("Failed to reap retained fixture: \(error)")
            return
        } catch {
            Issue.record("Failed to reap retained fixture: \(error)")
            return
        }
        Thread.sleep(forTimeInterval: 0.001)
    }
    Issue.record("Retained fixture was not reaped before its deadline")
}

private func expectReaped(_ processID: MojoPOSIXSupport.ProcessID) {
    #expect(!MojoPOSIXSupport.processGroupIsAlive(processID))
    do {
        _ = try MojoPOSIXSupport.waitNoHang(processID: processID)
        Issue.record("The attempt owner did not reap its child")
    } catch let error as MojoPOSIXSupportError {
        #expect(error == .childAlreadyReaped)
    } catch {
        Issue.record("Unexpected reap inspection error: \(error)")
    }
}
