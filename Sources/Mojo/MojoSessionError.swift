public enum MojoSessionError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case sessionDomainMismatch(expected: UInt64, actual: UInt64)
    case activeResources(Int)
    case resourceSessionMismatch
    case resourceFactoryMismatch(expected: UInt64, actual: UInt64)
    case duplicateResource
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
        case .resourceSessionMismatch:
            "The resource belongs to a different Mojo session instance"
        case .resourceFactoryMismatch(let expected, let actual):
            "The resource was created by factory \(actual), expected \(expected)"
        case .duplicateResource:
            "A mutable resource invocation cannot borrow the same resource twice"
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
