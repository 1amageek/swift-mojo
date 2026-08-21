public enum MojoSessionError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case sessionDomainMismatch(expected: UInt64, actual: UInt64)
    case activeResources(Int)
    case busy
    case resourceIdentifierExhausted
    case resourceShutdown
    case shutdown

    public var description: String {
        switch self {
        case .sessionDomainMismatch(let expected, let actual):
            "The Mojo session belongs to artifact domain \(actual), expected \(expected)"
        case .activeResources(let count):
            "The Mojo session still owns \(count) active resource(s)"
        case .busy:
            "The Mojo session is already executing a synchronous invocation"
        case .resourceIdentifierExhausted:
            "The Mojo session cannot register another owned resource"
        case .resourceShutdown:
            "The Mojo session resource has already shut down"
        case .shutdown:
            "The Mojo session has already shut down"
        }
    }
}
