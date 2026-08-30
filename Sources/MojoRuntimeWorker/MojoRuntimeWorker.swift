import Foundation
public import Mojo
import MojoPOSIXSupport
public import MojoRuntime

private enum MojoRuntimeWorkerAttemptOutcome<Value> {
    case success(Value)
    case bodyFailure(Error)
    case workerFailure(Error)
}

public struct MojoRuntimeWorker: Sendable {
    package let verification: MojoRuntimeWorkerBundleVerification

    public init(
        verification: MojoRuntimeWorkerBundleVerification
    ) throws {
        self.verification = verification
    }

    public func sessionFactory(
        for binding: MojoRuntimeWorkerBinding
    ) throws -> MojoRuntimeWorkerSessionFactory {
        try validatedMembership(of: binding)
        guard binding.signature == .runtimeSessionFactory else {
            throw MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [.runtimeSessionFactory],
                actual: binding.signature
            )
        }
        guard binding.sessionFactoryFunctionName == nil else {
            throw MojoRuntimeWorkerError
                .unexpectedSessionFactoryRelationship
        }
        return MojoRuntimeWorkerSessionFactory(
            bundleDigest: verification.bundleDigest,
            binding: binding
        )
    }

    public func float32Operation(
        for binding: MojoRuntimeWorkerBinding
    ) throws -> MojoRuntimeWorkerFloat32Operation {
        try validatedMembership(of: binding)

        switch binding.signature {
        case .borrowedFloat32Buffer, .borrowedMutableFloat32Buffers:
            guard binding.sessionFactoryFunctionName == nil else {
                throw MojoRuntimeWorkerError
                    .unexpectedSessionFactoryRelationship
            }
        case .sessionBorrowedMutableFloat32Buffers:
            guard let factoryName = binding.sessionFactoryFunctionName else {
                throw MojoRuntimeWorkerError
                    .missingSessionFactoryRelationship
            }
            guard verification.bindings.contains(where: {
                $0.functionName == factoryName
                    && $0.signature == .runtimeSessionFactory
                    && $0.sessionFactoryFunctionName == nil
            }) else {
                throw MojoRuntimeWorkerError
                    .unresolvedSessionFactoryRelationship
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

        return MojoRuntimeWorkerFloat32Operation(
            bundleDigest: verification.bundleDigest,
            binding: binding
        )
    }

    package func validatedBinding(
        for sessionFactory: MojoRuntimeWorkerSessionFactory
    ) throws -> MojoRuntimeWorkerBinding {
        guard sessionFactory.bundleDigest == verification.bundleDigest else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        _ = try self.sessionFactory(for: sessionFactory.binding)
        return sessionFactory.binding
    }

    package func validatedBinding(
        for operation: MojoRuntimeWorkerFloat32Operation
    ) throws -> MojoRuntimeWorkerBinding {
        guard operation.bundleDigest == verification.bundleDigest else {
            throw MojoRuntimeWorkerError.workerProjectionMismatch
        }
        _ = try float32Operation(for: operation.binding)
        return operation.binding
    }

    private func validatedMembership(
        of binding: MojoRuntimeWorkerBinding
    ) throws {
        guard verification.bindings.contains(binding) else {
            throw MojoRuntimeWorkerError.bindingNotInVerification
        }
    }

    public func withAttempt<Result: Sendable>(
        sessionFactory: MojoRuntimeWorkerSessionFactory,
        requirements: MojoSessionRequirements,
        timeouts: MojoRuntimeWorkerTimeouts,
        _ body: @Sendable (
            MojoRuntimeWorkerSession
        ) async throws -> Result
    ) async throws -> Result {
        try await withAttempt(
            sessionFactory: sessionFactory,
            requirements: requirements,
            timeouts: timeouts,
            admissionFactory: {
                MojoRuntimeWorkerArtifactAdmission()
            },
            wakeupFactory: {
                try MojoPOSIXWorkerSupport.createWakeup()
            },
            body
        )
    }

    package func withAttempt<Result: Sendable>(
        sessionFactory: MojoRuntimeWorkerSessionFactory,
        requirements: MojoSessionRequirements,
        timeouts: MojoRuntimeWorkerTimeouts,
        admissionFactory: @escaping @Sendable ()
            -> MojoRuntimeWorkerArtifactAdmission,
        wakeupFactory: @escaping @Sendable () throws
            -> MojoPOSIXWorkerWakeup = {
                try MojoPOSIXWorkerSupport.createWakeup()
            },
        _ body: @Sendable (
            MojoRuntimeWorkerSession
        ) async throws -> Result
    ) async throws -> Result {
        let factoryBinding = try validatedBinding(for: sessionFactory)
        let clock = ContinuousClock()
        let startupDeadline = clock.now.advanced(by: timeouts.startup)
        let admissionTask = Task.detached {
            try admissionFactory().admit(
                verification: self.verification,
                startupDeadline: startupDeadline,
                terminationGracePeriod: timeouts.terminationGracePeriod,
                forcedCleanup: timeouts.forcedCleanup
            )
        }
        let admitted: MojoRuntimeWorkerAdmittedProcess
        do {
            admitted = try await withTaskCancellationHandler(
                operation: {
                    try await admissionTask.value
                },
                onCancel: {
                    admissionTask.cancel()
                }
            )
        } catch {
            if error is CancellationError {
                throw MojoRuntimeWorkerError.cancellationRequested
            }
            throw error
        }

        let gate: MojoRuntimeWorkerCancellationGate
        do {
            let wakeup = try wakeupFactory()
            gate = MojoRuntimeWorkerCancellationGate(wakeup: wakeup)
        } catch {
            let failures = MojoRuntimeWorkerTerminalizer
                .cleanupAdmissionFailure(
                    process: admitted.process,
                    stageRoot: admitted.stage.rootURL,
                    terminationGracePeriod: timeouts.terminationGracePeriod,
                    forcedCleanup: timeouts.forcedCleanup
            )
            if failures.isEmpty {
                throw MojoRuntimeWorkerError.wakeupCreationFailed
            }
            throw MojoRuntimeWorkerError.cleanupFailed(
                primary: .worker(.wakeupCreationFailed),
                failures: failures
            )
        }

        let attempt = MojoRuntimeWorkerAttemptActor(
            admitted: admitted,
            gate: gate,
            factoryBinding: factoryBinding,
            requirements: requirements,
            timeouts: timeouts
        )
        let outcome: MojoRuntimeWorkerAttemptOutcome<Result>
        do {
            let sessionState = try await withTaskCancellationHandler(
                operation: {
                    try await attempt.createSession(
                        factory: sessionFactory,
                        deadline: clock.now.advanced(
                            by: timeouts.sessionCreation
                        )
                    )
                },
                onCancel: {
                    gate.cancelScope()
                }
            )
            let session = MojoRuntimeWorkerSessionFacade(
                state: sessionState,
                attempt: attempt
            )
            do {
                let result = try await withTaskCancellationHandler(
                    operation: {
                        try await body(session)
                    },
                    onCancel: {
                        gate.cancelScope()
                    }
                )
                outcome = .success(result)
            } catch {
                outcome = .bodyFailure(error)
            }
        } catch {
            outcome = .workerFailure(error)
        }

        let primary: MojoRuntimeWorkerError?
        switch outcome {
        case .success:
            primary = nil
        case .bodyFailure:
            primary = nil
        case .workerFailure(let error):
            primary = error as? MojoRuntimeWorkerError
        }
        let cleanupError = await attempt.finishAttempt(primary: primary)
        switch outcome {
        case .success(let result):
            if let cleanupError {
                throw cleanupError
            }
            return result
        case .bodyFailure(let error):
            if let cleanupError {
                if let failures = cleanupError.cleanupFailures {
                    throw MojoRuntimeWorkerError.cleanupFailed(
                        primary: .caller(
                            typeName: String(reflecting: type(of: error)),
                            description: String(describing: error)
                        ),
                        failures: failures
                    )
                }
                // Cleanup completed without a cleanup failure. Preserve the
                // exact original body error, including a worker-typed value.
                throw error
            }
            throw error
        case .workerFailure(let error):
            if let cleanupError {
                throw cleanupError
            }
            throw error
        }
    }
}
