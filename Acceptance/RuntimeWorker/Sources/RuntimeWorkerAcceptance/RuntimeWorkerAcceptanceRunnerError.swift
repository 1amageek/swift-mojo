import Foundation

public enum RuntimeWorkerAcceptanceRunnerError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case missingInput(String)
    case invalidInput(String)
    case dirtyExecutionEnvironment([String])
    case projectionMismatch(String)
    case authoringIdentityMismatch(String)
    case sourceIdentityContractMismatch(String)
    case sourceIdentityMismatch(expected: String, actual: String)
    case sourceIdentityChanged(before: String, after: String)
    case invalidVerifiedExecutionScript
    case processReplacementFailed(String)
    case consumerLaunchFailed(String)
    case consumerOutputFailed(String)
    case consumerTimedOut
    case consumerFailed(status: Int32, diagnostic: String)
    case invalidConsumerReport(String)
    case unexpectedOutput([UInt32])
    case stageLeak([String])
    case processLeak([String])
    case cleanupFailed(String)
    case processInspectionFailed(String)

    public var description: String {
        switch self {
        case .missingInput(let input):
            "Missing runtime-worker acceptance input: \(input)"
        case .invalidInput(let detail):
            "Invalid runtime-worker acceptance input: \(detail)"
        case .dirtyExecutionEnvironment(let names):
            "Execution environment is not clean: \(names.joined(separator: ", "))"
        case .projectionMismatch(let field):
            "Public W2 projection mapper mismatch at \(field)"
        case .authoringIdentityMismatch(let field):
            "Acceptance bundles do not share canonical authoring identity at \(field)"
        case .sourceIdentityContractMismatch(let field):
            "Acceptance source identity contract mismatch at \(field)"
        case .sourceIdentityMismatch(let expected, let actual):
            "Acceptance source identity mismatch: expected \(expected), actual \(actual)"
        case .sourceIdentityChanged(let before, let after):
            "Acceptance source identity changed during execution: \(before) -> \(after)"
        case .invalidVerifiedExecutionScript:
            "Verified acceptance execution script is not canonical UTF-8 text"
        case .processReplacementFailed(let detail):
            "Verified acceptance process replacement failed: \(detail)"
        case .consumerLaunchFailed(let detail):
            "Runtime-worker consumer launch failed: \(detail)"
        case .consumerOutputFailed(let detail):
            "Runtime-worker consumer output capture failed: \(detail)"
        case .consumerTimedOut:
            "Runtime-worker consumer exceeded its acceptance deadline"
        case .consumerFailed(let status, let diagnostic):
            "Runtime-worker consumer exited with status \(status): \(diagnostic)"
        case .invalidConsumerReport(let detail):
            "Runtime-worker consumer report is invalid: \(detail)"
        case .unexpectedOutput(let values):
            "Runtime-worker consumer returned unexpected Float32 bits: \(values)"
        case .stageLeak(let paths):
            "Runtime-worker private staging leaked: \(paths.joined(separator: ", "))"
        case .processLeak(let lines):
            "Runtime-worker process leaked: \(lines.joined(separator: " | "))"
        case .cleanupFailed(let detail):
            "Runtime-worker acceptance cleanup failed: \(detail)"
        case .processInspectionFailed(let detail):
            "Runtime-worker process inspection failed: \(detail)"
        }
    }
}
