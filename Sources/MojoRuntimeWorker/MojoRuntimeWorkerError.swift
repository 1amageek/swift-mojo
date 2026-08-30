public import MojoRuntime

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
    case privateStageRemovalFailed
    case privateStageRetained
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
    case stagedVerificationFailed
    case stagedProjectionMismatch
    case invalidExecutablePath
    case workerSpawnFailed
    case startupTimedOut
    case startupEOF(expected: Int, actual: Int)
    case startupProtocolFailed
    case readyMismatch(field: String)
    case startupFailure(
        code: MojoRuntimeWorkerRemoteFailureCode,
        diagnostic: String
    )
    case cleanupFailed(
        primary: MojoRuntimeWorkerError?,
        failures: [MojoRuntimeWorkerCleanupFailure]
    )

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
        case .stagedVerificationFailed:
            return "Staged worker verification failed"
        case .stagedProjectionMismatch:
            return "Staged worker projection differs from the selected "
                + "projection"
        case .invalidExecutablePath:
            return "Verified worker executable path is invalid"
        case .workerSpawnFailed:
            return "Worker spawn failed"
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
