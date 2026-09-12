/// An argument record was rejected before transmission.
public enum MojoInvocationArgumentError: Error, Equatable, Sendable {
    case tooManyValues
    case schemaMismatch
    case byteLimitExceeded
}
