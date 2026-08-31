import Foundation

enum RuntimeWorkerAcceptanceSourceRunnerError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidInput(String)
    case invalidVerifiedExecutionScript
    case processReplacementFailed(String)

    var description: String {
        switch self {
        case .invalidInput(let detail):
            "Invalid runtime-worker source authority input: \(detail)"
        case .invalidVerifiedExecutionScript:
            "Verified acceptance execution script is not canonical UTF-8 text"
        case .processReplacementFailed(let detail):
            "Verified acceptance process replacement failed: \(detail)"
        }
    }
}
