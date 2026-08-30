public enum RuntimeWorkerAcceptanceError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidContract(String)
    case invalidProjection(String)
    case invalidJSON(String)
    case nonCanonicalJSON

    public var description: String {
        switch self {
        case .invalidContract(let detail):
            "Invalid runtime-worker acceptance contract: \(detail)"
        case .invalidProjection(let detail):
            "Invalid runtime-worker verification projection: \(detail)"
        case .invalidJSON(let detail):
            "Invalid runtime-worker acceptance JSON: \(detail)"
        case .nonCanonicalJSON:
            "Runtime-worker acceptance JSON is not canonical"
        }
    }
}
