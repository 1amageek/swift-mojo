import Foundation
import Mojo
import MojoRuntime
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerSessionState: Sendable {
    package let capabilities: MojoSessionCapabilities

    package init(capabilities: MojoSessionCapabilities) {
        self.capabilities = capabilities
    }
}

package actor MojoRuntimeWorkerAttemptActor {
    private enum Phase: Sendable {
        case idle
        case live
        case closing
        case terminalizing
        case terminal
    }

    private enum FailureContext: Sendable {
        case general
        case sessionCreation
        case invocation
        case shutdown
    }

    private struct PendingExchange: Sendable {
        let nonce: UInt64
        let requestID: UInt64
        let lease: MojoRuntimeWorkerCancellationGate.Lease
        let deadline: ContinuousClock.Instant
    }

    private let admitted: MojoRuntimeWorkerAdmittedProcess
    private let gate: MojoRuntimeWorkerCancellationGate
    private let timeouts: MojoRuntimeWorkerTimeouts
    private let verification: MojoRuntimeWorkerBundleVerification
    private let factoryBinding: MojoRuntimeWorkerBinding
    private let requirements: MojoSessionRequirements

    private var sequence: MojoRuntimeProtocolSequenceValidator
    private var phase: Phase = .idle
    private var nextRequestID: UInt64 = 0
    private var pending: PendingExchange?
    private var inFlightTask:
        Task<MojoRuntimeWorkerExchangeResponse, Error>?
    private var inFlightCompletion: AsyncStream<Void>?
    private var inFlightCompletionContinuation:
        AsyncStream<Void>.Continuation?
    private var capabilities: MojoSessionCapabilities?
    private var terminalizationTask:
        Task<[MojoRuntimeWorkerCleanupFailure], Never>?
    private var terminalPrimary: MojoRuntimeWorkerError?
    private var terminalError: MojoRuntimeWorkerError?

    package init(
        admitted: MojoRuntimeWorkerAdmittedProcess,
        gate: MojoRuntimeWorkerCancellationGate,
        factoryBinding: MojoRuntimeWorkerBinding,
        requirements: MojoSessionRequirements,
        timeouts: MojoRuntimeWorkerTimeouts
    ) {
        self.admitted = admitted
        self.gate = gate
        self.timeouts = timeouts
        self.verification = admitted.verification
        self.factoryBinding = factoryBinding
        self.requirements = requirements
        self.sequence = admitted.sequence
        self.pendingPrefixData = nil
        self.pendingInput = nil
        self.inFlightTask = nil
        self.inFlightCompletion = nil
        self.inFlightCompletionContinuation = nil
    }

    package func createSession(
        factory: MojoRuntimeWorkerSessionFactory,
        deadline: ContinuousClock.Instant
    ) async throws -> MojoRuntimeWorkerSessionState {
        guard phase == .idle, pending == nil else {
            throw MojoRuntimeWorkerError.attemptClosed
        }
        guard factory.binding == factoryBinding,
              factory.bundleDigest == verification.bundleDigest else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        let payload = try MojoRuntimeCreateSessionPayload(
            bindingID: factoryBinding.bindingID,
            requestedDevice: requirements.device.rawValue,
            requestedOrdinal: requirements.ordinal,
            requiredCapabilities: requirements.requiredCapabilities.rawValue
        )
        let exchange = try startExchange(
            payload: .createSession(payload),
            input: nil,
            deadline: deadline,
            shielded: false
        )
        do {
            let response = try await awaitExchange(exchange)
            try ensurePending(exchange)
            try sequence.accept(response.frame, direction: .incoming)
            guard case .sessionCreated(let created) = response.frame.payload
            else {
                throw workerError(for: response.frame.payload)
            }
            guard let device = MojoDeviceKind(rawValue: created.actualDevice)
            else {
                throw MojoRuntimeWorkerError.invalidSessionDeviceKind(
                    rawValue: created.actualDevice
                )
            }
            let actual = MojoSessionCapabilities(
                device: device,
                ordinal: created.actualOrdinal,
                availableCapabilities: MojoSessionCapability(
                    rawValue: created.availableCapabilities
                )
            )
            guard actual.satisfies(requirements) else {
                throw MojoRuntimeWorkerError.sessionCapabilitiesUnsatisfied
            }
            guard ContinuousClock().now < exchange.deadline else {
                throw MojoRuntimeWorkerError.sessionCreationTimedOut
            }
            guard gate.commitResponse(for: exchange.lease) else {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            finishExchange(exchange)
            capabilities = actual
            phase = .live
            return MojoRuntimeWorkerSessionState(capabilities: actual)
        } catch {
            finishExchange(exchange)
            let primary = workerError(error, context: .sessionCreation)
            if phase == .terminalizing || phase == .terminal {
                let existing = await awaitTerminalization()
                throw existing ?? primary
            }
            throw (await terminalize(primary: primary, mode: .hard) ?? primary)
        }
    }

    package func invoke(
        _ operation: MojoRuntimeWorkerFloat32Operation,
        input: [Float],
        outputElementCount: Int,
        timeout: Duration
    ) async throws -> [Float] {
        guard phase == .live else {
            throw MojoRuntimeWorkerError.attemptClosed
        }
        guard pending == nil else {
            throw MojoRuntimeWorkerError.operationInProgress
        }
        try MojoRuntimeWorkerTimeouts.validateInvocation(timeout)
        let binding = try validatedOperation(operation)
        guard !input.isEmpty else {
            throw MojoRuntimeWorkerError.emptyInput
        }
        switch binding.signature {
        case .borrowedFloat32Buffer:
            guard outputElementCount == 1 else {
                throw MojoRuntimeWorkerError.invalidOutputElementCount
            }
        case .borrowedMutableFloat32Buffers,
             .sessionBorrowedMutableFloat32Buffers:
            guard outputElementCount > 0 else {
                throw MojoRuntimeWorkerError.invalidOutputElementCount
            }
        case .int32Binary, .borrowedMutableFloat64Buffers,
             .runtimeSessionFactory, .sessionFloat32BufferFactory:
            throw MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [
                    .borrowedFloat32Buffer,
                    .borrowedMutableFloat32Buffers,
                    .sessionBorrowedMutableFloat32Buffers,
                ],
                actual: binding.signature
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let payload = try MojoRuntimeInvokeFloat32Payload(
            bindingID: binding.bindingID,
            inputElementCount: UInt64(input.count),
            outputElementCount: UInt64(outputElementCount)
        )
        let exchange = try startExchange(
            payload: .invokeFloat32(payload),
            input: input,
            deadline: deadline,
            shielded: false
        )
        do {
            let response = try await awaitExchange(exchange)
            try ensurePending(exchange)
            try sequence.accept(response.frame, direction: .incoming)
            guard case .invocationResult(let result) = response.frame.payload
            else {
                throw workerError(for: response.frame.payload)
            }
            guard result.status == 0 else {
                guard gate.commitResponse(for: exchange.lease) else {
                    throw MojoRuntimeWorkerError.cancellationRequested
                }
                finishExchange(exchange)
                throw MojoRuntimeWorkerError.invocationFailed(
                    status: result.status
                )
            }
            guard result.resultElementCount
                    == UInt64(outputElementCount),
                  response.output.count == outputElementCount else {
                throw MojoRuntimeWorkerError.responseMismatch
            }
            let clock = ContinuousClock()
            guard clock.now < exchange.deadline else {
                throw MojoRuntimeWorkerError.invocationTimedOut
            }
            guard gate.commitResponse(for: exchange.lease) else {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            finishExchange(exchange)
            return response.output
        } catch {
            finishExchange(exchange)
            if case MojoRuntimeWorkerError.invocationFailed = error {
                throw error
            }
            let primary = workerError(error, context: .invocation)
            if phase == .closing {
                throw primary
            }
            if phase == .terminalizing || phase == .terminal {
                let existing = await awaitTerminalization()
                throw existing ?? primary
            }
            throw (await terminalize(primary: primary, mode: .hard) ?? primary)
        }
    }

    package func finishAttempt(
        primary: MojoRuntimeWorkerError? = nil
    ) async -> MojoRuntimeWorkerError? {
        if phase == .terminal {
            return terminalError
        }
        if phase == .terminalizing {
            return await awaitTerminalization()
        }
        if let pending {
            phase = .closing
            let completion = inFlightCompletion
            pending.lease.cancel()
            await awaitInFlightTask()
            await awaitExchangeCompletion(completion)
            return await terminalize(
                primary: primary ?? .cancellationRequested,
                mode: .hard
            )
        }
        guard phase == .live else {
            return await terminalize(primary: primary, mode: .hard)
        }
        do {
            let clock = ContinuousClock()
            let gracefulDeadline = clock.now.advanced(
                by: timeouts.gracefulShutdown
            )
            try await shutdownGracefully(until: gracefulDeadline)
            return await terminalize(
                primary: primary,
                mode: .graceful,
                gracefulDeadline: gracefulDeadline
            )
        } catch {
            let shutdownFailure = workerError(error, context: .shutdown)
            if phase == .terminalizing || phase == .terminal {
                return await awaitTerminalization()
            }
            return await terminalize(
                primary: primary ?? shutdownFailure,
                mode: .hard
            )
        }
    }

    package func explicitShutdown() async throws {
        if phase == .terminal {
            if let terminalError {
                throw terminalError
            }
            return
        }
        if phase == .terminalizing {
            if let terminalError = await awaitTerminalization() {
                throw terminalError
            }
            return
        }
        guard phase == .live, pending == nil else {
            throw MojoRuntimeWorkerError.operationInProgress
        }
        do {
            let clock = ContinuousClock()
            let gracefulDeadline = clock.now.advanced(
                by: timeouts.gracefulShutdown
            )
            try await shutdownGracefully(until: gracefulDeadline)
            if let terminalError = await terminalize(
                primary: nil,
                mode: .graceful,
                gracefulDeadline: gracefulDeadline
            ) {
                throw terminalError
            }
        } catch {
            let primary = workerError(error, context: .shutdown)
            let terminalError = await terminalize(
                primary: primary,
                mode: .hard
            )
            throw terminalError ?? primary
        }
    }

    package func isShutdown() -> Bool {
        switch phase {
        case .idle, .live:
            return false
        case .closing, .terminalizing, .terminal:
            return true
        }
    }

    package func hasInFlightExchange() -> Bool {
        pending != nil
    }

    private func shutdownGracefully(
        until deadline: ContinuousClock.Instant
    ) async throws {
        phase = .closing
        let sessionExchange = try startExchange(
            payload: .shutdownSession,
            input: nil,
            deadline: deadline,
            shielded: true
        )
        do {
            let response = try await awaitExchange(sessionExchange)
            try ensurePending(sessionExchange)
            try sequence.accept(response.frame, direction: .incoming)
            guard case .sessionShutdown = response.frame.payload else {
                throw workerError(for: response.frame.payload)
            }
            guard ContinuousClock().now < sessionExchange.deadline else {
                throw MojoRuntimeWorkerError.shutdownTimedOut
            }
            guard gate.commitResponse(for: sessionExchange.lease) else {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            finishExchange(sessionExchange)
        } catch {
            finishExchange(sessionExchange)
            throw workerError(error, context: .shutdown)
        }

        let workerExchange = try startExchange(
            payload: .shutdownWorker,
            input: nil,
            deadline: deadline,
            shielded: true
        )
        do {
            let response = try await awaitExchange(workerExchange)
            try ensurePending(workerExchange)
            try sequence.accept(response.frame, direction: .incoming)
            guard case .workerShutdown = response.frame.payload else {
                throw workerError(for: response.frame.payload)
            }
            guard ContinuousClock().now < workerExchange.deadline else {
                throw MojoRuntimeWorkerError.shutdownTimedOut
            }
            guard gate.commitResponse(for: workerExchange.lease) else {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            finishExchange(workerExchange)
        } catch {
            finishExchange(workerExchange)
            throw workerError(error, context: .shutdown)
        }
    }

    private func startExchange(
        payload: MojoRuntimePayload,
        input: [Float]?,
        deadline: ContinuousClock.Instant,
        shielded: Bool
    ) throws -> PendingExchange {
        let lease = try gate.beginExchange(shielded: shielded)
        do {
            guard nextRequestID < UInt64.max else {
                throw MojoRuntimeWorkerError.requestIdentifierExhausted
            }
            nextRequestID += 1
            let requestID = nextRequestID
            let frame = try MojoRuntimeFrame(
                requestID: requestID,
                payload: payload,
                limits: admitted.protocolLimits
            )
            let prefixData = try frame.encodedPrefixData(
                limits: admitted.protocolLimits
            )
            try sequence.accept(frame, direction: .outgoing)
            let exchange = PendingExchange(
                nonce: lease.generation,
                requestID: requestID,
                lease: lease,
                deadline: deadline
            )
            let completion = AsyncStream<Void>.makeStream()
            inFlightCompletion = completion.stream
            inFlightCompletionContinuation = completion.continuation
            pendingPrefixData = prefixData
            pendingInput = input
            pending = exchange
            // The owned command is the only value crossing into the detached
            // task. Its Float array is retained by value; no pointer escapes.
            return exchange
        } catch {
            gate.endExchange(for: lease)
            throw workerError(error)
        }
    }

    private func awaitExchange(
        _ exchange: PendingExchange
    ) async throws -> MojoRuntimeWorkerExchangeResponse {
        guard pendingMatches(exchange) else {
            throw MojoRuntimeWorkerError.attemptClosed
        }
        let command = MojoRuntimeWorkerExchangeCommand(
            process: admitted.process,
            protocolLimits: admitted.protocolLimits,
            gate: gate,
            lease: exchange.lease,
            prefixData: try prefixData(for: exchange),
            input: input(for: exchange),
            deadline: exchange.deadline
        )
        let task = MojoRuntimeWorkerTransport.detached(command)
        inFlightTask = task
        gate.beginHandler()
        defer { gate.endHandler() }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: {
            exchange.lease.cancel()
        })
    }

    private func awaitInFlightTask() async {
        guard let inFlightTask else { return }
        do {
            _ = try await inFlightTask.value
        } catch {
            // The caller that owns the exchange reports its typed primary
            // failure. This barrier only protects descriptor lifetime.
        }
    }

    // The command data is retained by the pending exchange until the actor
    // starts its detached operation. These fields are populated immediately
    // after startExchange and are cleared with the pending exchange.
    private var pendingPrefixData: Data?
    private var pendingInput: [Float]?

    private func prefixData(
        for exchange: PendingExchange
    ) throws -> Data {
        guard pendingMatches(exchange), let prefixData = pendingPrefixData else {
            throw MojoRuntimeWorkerError.attemptClosed
        }
        return prefixData
    }

    private func input(for exchange: PendingExchange) -> [Float]? {
        guard pendingMatches(exchange) else { return nil }
        return pendingInput
    }

    private func pendingMatches(_ exchange: PendingExchange) -> Bool {
        guard let pending else { return false }
        return pending.nonce == exchange.nonce
            && pending.requestID == exchange.requestID
    }

    private func ensurePending(_ exchange: PendingExchange) throws {
        guard pendingMatches(exchange), phase != .terminalizing,
              phase != .terminal else {
            throw MojoRuntimeWorkerError.attemptClosed
        }
    }

    private func finishExchange(_ exchange: PendingExchange) {
        guard pendingMatches(exchange) else { return }
        pending = nil
        pendingPrefixData = nil
        pendingInput = nil
        inFlightTask = nil
        inFlightCompletionContinuation?.yield(())
        inFlightCompletionContinuation?.finish()
        inFlightCompletionContinuation = nil
        inFlightCompletion = nil
        gate.endExchange(for: exchange.lease)
    }

    private func awaitExchangeCompletion(
        _ completion: AsyncStream<Void>?
    ) async {
        guard let completion else { return }
        var iterator = completion.makeAsyncIterator()
        _ = await iterator.next()
    }

    private func validatedOperation(
        _ operation: MojoRuntimeWorkerFloat32Operation
    ) throws -> MojoRuntimeWorkerBinding {
        guard operation.bundleDigest == verification.bundleDigest,
              verification.bindings.contains(operation.binding) else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        let binding = operation.binding
        switch binding.signature {
        case .borrowedFloat32Buffer, .borrowedMutableFloat32Buffers:
            guard binding.sessionFactoryFunctionName == nil else {
                throw MojoRuntimeWorkerError.unexpectedSessionFactoryRelationship
            }
        case .sessionBorrowedMutableFloat32Buffers:
            guard binding.sessionFactoryFunctionName == factoryBinding
                .functionName else {
                throw MojoRuntimeWorkerError.missingSessionFactoryRelationship
            }
        case .int32Binary, .borrowedMutableFloat64Buffers,
             .runtimeSessionFactory, .sessionFloat32BufferFactory:
            break
        }
        return binding
    }

    private func terminalize(
        primary: MojoRuntimeWorkerError?,
        mode: MojoRuntimeWorkerTerminalizer.Mode,
        gracefulDeadline suppliedGracefulDeadline:
            ContinuousClock.Instant? = nil
    ) async -> MojoRuntimeWorkerError? {
        if phase == .terminal {
            return terminalError ?? primary
        }
        if let terminalizationTask {
            _ = await terminalizationTask.value
            return terminalError ?? primary
        }
        terminalPrimary = primary
        let clock = ContinuousClock()
        let phaseStart = clock.now
        let gracefulDeadline = suppliedGracefulDeadline ?? phaseStart.advanced(
            by: timeouts.gracefulShutdown
        )
        let terminationDeadline: ContinuousClock.Instant
        let forcedCleanupDeadline: ContinuousClock.Instant
        switch mode {
        case .graceful:
            terminationDeadline = gracefulDeadline.advanced(
                by: timeouts.terminationGracePeriod
            )
            forcedCleanupDeadline = terminationDeadline.advanced(
                by: timeouts.forcedCleanup
            )
        case .hard:
            terminationDeadline = phaseStart.advanced(
                by: timeouts.terminationGracePeriod
            )
            forcedCleanupDeadline = terminationDeadline.advanced(
                by: timeouts.forcedCleanup
            )
        }
        let process = admitted.process
        let stageRoot = admitted.stage.rootURL
        let gate = self.gate
        let claim = admitted.claimTerminalCleanup()
        let task: Task<[MojoRuntimeWorkerCleanupFailure], Never> = Task.detached {
            guard claim else {
                return [MojoRuntimeWorkerCleanupFailure]()
            }
            return MojoRuntimeWorkerTerminalizer.cleanup(
                process: process,
                stageRoot: stageRoot,
                gate: gate,
                mode: mode,
                gracefulDeadline: gracefulDeadline,
                terminationDeadline: terminationDeadline,
                forcedCleanupDeadline: forcedCleanupDeadline
            )
        }
        terminalizationTask = task
        phase = .terminalizing
        let failures = await task.value
        phase = .terminal
        if let primary {
            terminalError = failures.isEmpty
                ? primary
                : .cleanupFailed(
                    primary: .worker(primary),
                    failures: failures
                )
        } else if !failures.isEmpty {
            terminalError = .cleanupFailed(primary: nil, failures: failures)
        }
        return terminalError
    }

    private func awaitTerminalization() async -> MojoRuntimeWorkerError? {
        guard let terminalizationTask else { return terminalError }
        let failures = await terminalizationTask.value
        if phase != .terminal {
            phase = .terminal
            if let primary = terminalPrimary {
                terminalError = failures.isEmpty
                    ? primary
                    : .cleanupFailed(
                        primary: .worker(primary),
                        failures: failures
                    )
            } else if !failures.isEmpty {
                terminalError = .cleanupFailed(
                    primary: nil,
                    failures: failures
                )
            }
        }
        return terminalError
    }

    private func workerError(
        _ error: Error,
        context: FailureContext = .general
    ) -> MojoRuntimeWorkerError {
        if let error = error as? MojoRuntimeWorkerError {
            switch (context, error) {
            case (.sessionCreation, .invocationTimedOut):
                return .sessionCreationTimedOut
            case (.shutdown, .invocationTimedOut):
                return .shutdownTimedOut
            default:
                return error
            }
        }
        if let error = error as? MojoRuntimeProtocolError {
            return .protocolError(error)
        }
        return .protocolFailure
    }

    private func workerError(
        for payload: MojoRuntimePayload
    ) -> MojoRuntimeWorkerError {
        guard case .failure(let failure) = payload else {
            return .responseMismatch
        }
        guard let code = MojoRuntimeWorkerRemoteFailureCode(
            rawValue: failure.code.rawValue
        ) else {
            return .protocolFailure
        }
        return .remoteFailure(
            code: code,
            diagnostic: String(
                decoding: failure.diagnostic,
                as: UTF8.self
            )
        )
    }
}
