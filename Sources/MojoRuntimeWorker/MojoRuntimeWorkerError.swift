public import MojoRuntime
import MojoRuntimeProtocolCore

public enum MojoRuntimeWorkerProtocolFailureKind:
    String, Equatable, Sendable
{
    case invalidHeader
    case unsupportedSchema
    case malformedFrame
    case payloadLimitExceeded
    case truncatedFrame
    case trailingFrameBytes
    case sequenceViolation
    case responseMismatch
    case secondInFlight
    case invalidDigest
    case invalidLimit
}

public enum MojoRuntimeWorkerRemoteFailureCode:
    UInt16, Equatable, Sendable
{
    case invalidFrame = 1
    case invalidSequence = 2
    case invalidBinding = 3
    case sessionUnavailable = 4
    case invocationFailed = 5
    case shutdownFailed = 6
    case internalFailure = 7
}

public enum MojoRuntimeWorkerCleanupFailure:
    String, Equatable, Sendable
{
    case transportCloseFailed
    case processInspectionFailed
    case processTerminationFailed
    case processReapFailed
    case processGroupTerminationFailed
    case diagnosticsCloseFailed
    case wakeupSignalFailed
    case wakeupCloseFailed
    case privateStageRemovalFailed
    case privateStageRetained
    case inputResourceCloseFailed
}

public enum MojoRuntimeWorkerTimeoutField: String, Equatable, Sendable {
    case startup
    case sessionCreation
    case gracefulShutdown
    case terminationGracePeriod
    case forcedCleanup
    case invocation
}

public enum MojoRuntimeWorkerPrimaryFailure:
    Equatable, Sendable, CustomStringConvertible
{
    case worker(MojoRuntimeWorkerError)
    case caller(typeName: String, description: String)

    public var description: String {
        switch self {
        case .worker(let error):
            return "worker(\(error))"
        case .caller(let typeName, let description):
            return "caller(\(typeName)): \(description)"
        }
    }
}

public indirect enum MojoRuntimeWorkerError:
    Error, Equatable, Sendable, CustomStringConvertible
{
    case bindingNotInVerification
    case unsupportedBindingSignature(
        expected: [MojoRuntimeWorkerBindingSignature],
        actual: MojoRuntimeWorkerBindingSignature
    )
    case missingSessionFactoryRelationship
    case unexpectedSessionFactoryRelationship
    case unresolvedSessionFactoryRelationship
    case workerProjectionMismatch
    case privateStageCreationFailed
    case privateStagePermissions(actual: Int)
    case privateStageCopyFailed
    case invalidInputResourceIdentity
    case inputResourceUnavailable
    case inputResourceByteCountMismatch
    case inputResourceDigestMismatch
    case inputResourceCopyFailed
    case inputResourcePermissionFailed
    case stagedVerificationFailed
    case stagedProjectionMismatch
    case invalidExecutablePath
    case workerSpawnFailed
    case wakeupCreationFailed
    case invalidTimeout(field: MojoRuntimeWorkerTimeoutField)
    case emptyInput
    case invalidOutputElementCount
    case payloadLimitExceeded
    case attemptClosed
    case sessionBusy
    case cancellationRequested
    case invocationTimedOut
    case workerExited
    case protocolFailure
    case protocolViolation(kind: MojoRuntimeWorkerProtocolFailureKind)
    case requestIdentifierExhausted
    case responseMismatch
    case schemaMismatch(expected: UInt32, actual: UInt32)
    case invalidSessionDeviceKind(rawValue: UInt32)
    case sessionCapabilitiesUnsatisfied
    case invocationFailed(status: Int32)
    case sessionCreationFailed
    case sessionCreationTimedOut
    case shutdownTimedOut
    case remoteFailure(
        code: MojoRuntimeWorkerRemoteFailureCode,
        diagnostic: String
    )
    case operationInProgress
    case startupTimedOut
    case startupEOF(expected: Int, actual: Int)
    case startupProtocolFailed
    case readyMismatch(field: String)
    case startupFailure(
        code: MojoRuntimeWorkerRemoteFailureCode,
        diagnostic: String
    )
    case cleanupFailed(
        primary: MojoRuntimeWorkerPrimaryFailure?,
        failures: [MojoRuntimeWorkerCleanupFailure]
    )

    package var cleanupFailures: [MojoRuntimeWorkerCleanupFailure]? {
        guard case .cleanupFailed(_, let failures) = self else {
            return nil
        }
        return failures
    }

    public var description: String {
        switch self {
        case .bindingNotInVerification:
            return "Binding is not a member of the verified worker projection"
        case .unsupportedBindingSignature(let expected, let actual):
            let expectedDescription = expected.map(\.rawValue)
                .joined(separator: ", ")
            return "Worker binding signature '\(actual.rawValue)' is "
                + "unsupported; expected one of \(expectedDescription)"
        case .missingSessionFactoryRelationship:
            return "Session-bound worker operation has no session factory relationship"
        case .unexpectedSessionFactoryRelationship:
            return "Worker binding unexpectedly declares a session factory relationship"
        case .unresolvedSessionFactoryRelationship:
            return "Worker binding references no verified session factory"
        case .workerProjectionMismatch:
            return "Worker token belongs to a different verified projection"
        case .privateStageCreationFailed:
            return "Private worker staging creation failed"
        case .privateStagePermissions(let actual):
            return "Private worker staging permissions are invalid: \(actual)"
        case .privateStageCopyFailed:
            return "Private worker staging copy failed"
        case .invalidInputResourceIdentity:
            return "Input resource requires a file URL, positive byte count, and lowercase SHA-256"
        case .inputResourceUnavailable:
            return "Input resource is missing, linked, or not a readable regular file"
        case .inputResourceByteCountMismatch:
            return "Input resource byte count differs from its selected identity"
        case .inputResourceDigestMismatch:
            return "Input resource digest differs from its selected identity"
        case .inputResourceCopyFailed:
            return "Private input resource copy failed"
        case .inputResourcePermissionFailed:
            return "Private input resource could not be made read-only"
        case .stagedVerificationFailed:
            return "Staged worker verification failed"
        case .stagedProjectionMismatch:
            return "Staged worker projection differs from the selected "
                + "projection"
        case .invalidExecutablePath:
            return "Verified worker executable path is invalid"
        case .workerSpawnFailed:
            return "Worker spawn failed"
        case .wakeupCreationFailed:
            return "Worker cancellation wakeup creation failed"
        case .invalidTimeout(let field):
            return "Worker timeout '\(field)' must be finite and positive"
        case .emptyInput:
            return "Worker invocation requires a non-empty Float32 input"
        case .invalidOutputElementCount:
            return "Worker invocation output element count is invalid"
        case .payloadLimitExceeded:
            return "Worker invocation exceeds the verified protocol payload limit"
        case .attemptClosed:
            return "The worker attempt is closed"
        case .sessionBusy:
            return "The worker attempt already has an in-flight operation"
        case .cancellationRequested:
            return "The worker operation was cancelled"
        case .invocationTimedOut:
            return "The worker invocation timed out"
        case .workerExited:
            return "The worker exited before completing the operation"
        case .protocolFailure:
            return "The worker protocol exchange failed"
        case .protocolViolation(let kind):
            return "The worker protocol exchange failed: \(kind.rawValue)"
        case .requestIdentifierExhausted:
            return "The worker request identifier space is exhausted"
        case .responseMismatch:
            return "The worker response does not match the in-flight request"
        case .schemaMismatch(let expected, let actual):
            return "The worker session schema is \(actual), expected \(expected)"
        case .invalidSessionDeviceKind(let rawValue):
            return "The worker returned unknown session device kind \(rawValue)"
        case .sessionCapabilitiesUnsatisfied:
            return "The worker session capabilities do not satisfy the request"
        case .invocationFailed(let status):
            return "The worker invocation failed with status \(status)"
        case .sessionCreationFailed:
            return "The worker session could not be created"
        case .sessionCreationTimedOut:
            return "Worker session creation timed out"
        case .shutdownTimedOut:
            return "Worker shutdown timed out"
        case .remoteFailure(let code, let diagnostic):
            return "The worker reported failure \(code): \(diagnostic)"
        case .operationInProgress:
            return "The worker attempt has an operation in progress"
        case .startupTimedOut:
            return "Worker startup timed out"
        case .startupEOF(let expected, let actual):
            return "Worker startup ended after \(actual) bytes; expected "
                + "\(expected)"
        case .startupProtocolFailed:
            return "Worker startup protocol failed"
        case .readyMismatch(let field):
            return "Worker ready identity differs at field '\(field)'"
        case .startupFailure(let code, let diagnostic):
            return "Worker startup failed with code '\(code)': \(diagnostic)"
        case .cleanupFailed(let primary, let failures):
            let primaryDescription = primary.map(String.init(describing:))
                ?? "none"
            let cleanupDescription = failures.map(\.rawValue)
                .joined(separator: "; ")
            return "Worker cleanup failed; primary: \(primaryDescription); "
                + "cleanup: \(cleanupDescription)"
        }
    }
}

extension MojoRuntimeWorkerError {
    package static func protocolError(
        _ error: MojoRuntimeProtocolError
    ) -> Self {
        switch error {
        case .invalidMagic, .reservedFieldNonZero,
             .invalidRequestIdentifier:
            return .protocolViolation(kind: .invalidHeader)
        case .invalidVersion, .schemaMismatch:
            if case .schemaMismatch(let expected, let actual) = error {
                return .schemaMismatch(expected: expected, actual: actual)
            }
            return .protocolViolation(kind: .unsupportedSchema)
        case .unknownKind:
            return .protocolViolation(kind: .malformedFrame)
        case .invalidPayloadLength, .integerOverflow,
             .invalidPayload, .invalidUTF8,
             .tensorBodyRequiresBorrowedSegment, .unexpectedFrame:
            return .protocolViolation(kind: .malformedFrame)
        case .payloadTooLarge:
            return .payloadLimitExceeded
        case .truncatedHeader, .truncatedPayload:
            return .protocolViolation(kind: .truncatedFrame)
        case .trailingBytes:
            return .protocolViolation(kind: .trailingFrameBytes)
        case .invalidDigest:
            return .protocolViolation(kind: .invalidDigest)
        case .invalidLimit:
            return .protocolViolation(kind: .invalidLimit)
        case .sequenceViolation:
            return .protocolViolation(kind: .sequenceViolation)
        case .responseIdentifierMismatch, .responseKindMismatch:
            return .responseMismatch
        case .secondInFlight:
            return .protocolViolation(kind: .secondInFlight)
        }
    }
}
