import MojoRuntimeProtocolCore

/// Numeric interpretation of a buffer view, independent of its producer.
public enum MojoBufferElementType: CaseIterable, Hashable, Sendable {
    case int8, uint8, int16, uint16, int32, uint32
    case int64, uint64, float16, float32, float64

    public var byteWidth: Int { Int(wireType.byteWidth) }

    package var wireType: MojoRuntimeElementType {
        switch self {
        case .int8: .int8
        case .uint8: .uint8
        case .int16: .int16
        case .uint16: .uint16
        case .int32: .int32
        case .uint32: .uint32
        case .int64: .int64
        case .uint64: .uint64
        case .float16: .float16
        case .float32: .float32
        case .float64: .float64
        }
    }
}
