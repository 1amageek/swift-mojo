import Foundation
import MojoRuntimeProtocolCore

/// A fixed-width scalar. Floating-point encoding preserves the supplied bit pattern.
public enum MojoInvocationValue: Sendable {
    case int8(Int8), uint8(UInt8), int16(Int16), uint16(UInt16)
    case int32(Int32), uint32(UInt32), int64(Int64), uint64(UInt64)
    case float16(Float16), float32(Float), float64(Double)

    package var type: MojoRuntimeElementType {
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

    package func append(to data: inout Data) {
        func append<Integer: FixedWidthInteger>(_ value: Integer) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        switch self {
        case .int8(let value): append(value)
        case .uint8(let value): append(value)
        case .int16(let value): append(value)
        case .uint16(let value): append(value)
        case .int32(let value): append(value)
        case .uint32(let value): append(value)
        case .int64(let value): append(value)
        case .uint64(let value): append(value)
        case .float16(let value): append(value.bitPattern)
        case .float32(let value): append(value.bitPattern)
        case .float64(let value): append(value.bitPattern)
        }
    }
}
