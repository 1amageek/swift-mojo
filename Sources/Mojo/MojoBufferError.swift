public enum MojoBufferError: Error, Equatable, Sendable,
    CustomStringConvertible {
    case missingCapabilities(
        required: MojoSessionCapability,
        available: MojoSessionCapability
    )
    case elementCountMismatch(expected: UInt64, actual: UInt64)
    case sizeOverflow(elementCount: UInt64, elementStride: UInt64)
    case zeroElementCountUnsupported

    public var description: String {
        switch self {
        case .elementCountMismatch(let expected, let actual):
            "The Mojo buffer contains \(expected) elements, but the host buffer contains \(actual)"
        case .missingCapabilities(let required, let available):
            "The Mojo buffer requires capabilities \(required.rawValue), but the session provides \(available.rawValue)"
        case .sizeOverflow(let elementCount, let elementStride):
            "The Mojo buffer byte count overflows for \(elementCount) elements with stride \(elementStride)"
        case .zeroElementCountUnsupported:
            "The Mojo buffer v1 ABI requires at least one element"
        }
    }
}
