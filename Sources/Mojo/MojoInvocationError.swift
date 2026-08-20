public enum MojoInvocationError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case bindingUnavailable(bindingID: UInt64)
    case incompatibleStaticABI(expected: UInt32, actual: UInt32)
    case inputGraphMismatch(expected: UInt64, actual: UInt64)
    case emptyBorrowedBuffer

    public var description: String {
        switch self {
        case .bindingUnavailable(let bindingID):
            "The prepared Mojo artifact does not contain binding \(bindingID)"
        case .incompatibleStaticABI(let expected, let actual):
            "The linked Mojo static ABI is version \(actual), expected \(expected)"
        case .inputGraphMismatch(let expected, let actual):
            "The linked Mojo input graph is \(actual), expected \(expected)"
        case .emptyBorrowedBuffer:
            "The Mojo call requires a non-empty Float buffer"
        }
    }
}
