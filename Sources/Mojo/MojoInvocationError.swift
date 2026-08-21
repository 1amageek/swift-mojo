public enum MojoInvocationError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case bindingUnavailable(bindingID: UInt64)
    case incompatibleStaticABI(expected: UInt32, actual: UInt32)
    case inputGraphMismatch(expected: UInt64, actual: UInt64)
    case emptyBorrowedBuffer
    case emptyMutableBuffer
    case invalidSessionDeviceKind(bindingID: UInt64, rawValue: UInt32)
    case invalidSessionResponseSchema(
        bindingID: UInt64,
        expected: UInt32,
        actual: UInt32
    )
    case invocationFailed(bindingID: UInt64, status: Int32)
    case resourceCreationReturnedNoHandle(bindingID: UInt64)
    case sessionCreationReturnedNoHandle(bindingID: UInt64)
    case sessionRequirementsUnsatisfied(
        bindingID: UInt64,
        requirements: MojoSessionRequirements,
        actual: MojoSessionCapabilities
    )

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
        case .emptyMutableBuffer:
            "The Mojo call requires a non-empty mutable Float buffer"
        case .invalidSessionDeviceKind(let bindingID, let rawValue):
            "Mojo session binding \(bindingID) returned unknown device kind \(rawValue)"
        case .invalidSessionResponseSchema(
            let bindingID,
            let expected,
            let actual
        ):
            "Mojo session binding \(bindingID) returned response schema \(actual), expected \(expected)"
        case .invocationFailed(let bindingID, let status):
            "Mojo binding \(bindingID) failed with status \(status)"
        case .resourceCreationReturnedNoHandle(let bindingID):
            "Mojo resource binding \(bindingID) succeeded without returning a handle"
        case .sessionCreationReturnedNoHandle(let bindingID):
            "Mojo session binding \(bindingID) succeeded without returning a handle"
        case .sessionRequirementsUnsatisfied(
            let bindingID,
            let requirements,
            let actual
        ):
            "Mojo session binding \(bindingID) returned device \(actual.device.rawValue):\(actual.ordinal) with capabilities \(actual.availableCapabilities.rawValue), which does not satisfy requested device \(requirements.device.rawValue):\(requirements.ordinal) and capabilities \(requirements.requiredCapabilities.rawValue)"
        }
    }
}
