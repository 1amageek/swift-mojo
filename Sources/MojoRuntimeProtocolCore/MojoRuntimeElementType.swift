/// Canonical v2 storage element identifiers, independent of host ABI.
package enum MojoRuntimeElementType: UInt16, CaseIterable, Sendable {
    case int8 = 1, uint8, int16, uint16, int32, uint32
    case int64, uint64, float16, float32, float64

    package var byteWidth: UInt64 {
        switch self {
        case .int8, .uint8: 1
        case .int16, .uint16, .float16: 2
        case .int32, .uint32, .float32: 4
        case .int64, .uint64, .float64: 8
        }
    }
}
