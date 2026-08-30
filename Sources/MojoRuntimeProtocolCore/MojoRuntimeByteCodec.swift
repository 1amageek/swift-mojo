import Foundation

package struct MojoRuntimeByteWriter: Sendable {
    package private(set) var bytes: [UInt8] = []

    package init(reservingCapacity capacity: Int = 0) {
        guard capacity >= 0 else { return }
        bytes.reserveCapacity(capacity)
    }

    package mutating func append(_ byte: UInt8) {
        bytes.append(byte)
    }

    package mutating func append(contentsOf values: [UInt8]) {
        bytes.append(contentsOf: values)
    }

    package mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    package mutating func appendUInt32(_ value: UInt32) {
        for shift in stride(from: 0, through: 24, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    package mutating func appendUInt64(_ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    package mutating func appendInt32(_ value: Int32) {
        appendUInt32(UInt32(bitPattern: value))
    }

    package mutating func appendFloat32(_ value: Float32) {
        appendUInt32(value.bitPattern)
    }

    package mutating func appendLengthPrefixedString(
        _ value: String,
        maximumByteCount: Int
    ) throws {
        guard maximumByteCount >= 0 else {
            throw MojoRuntimeProtocolError.invalidLimit
        }
        let data = Data(value.utf8)
        guard data.count <= maximumByteCount,
              data.count <= UInt16.max else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .ready,
                reason: "text field exceeds its bounded prefix"
            )
        }
        appendUInt16(UInt16(data.count))
        append(contentsOf: Array(data))
    }

    package func data() -> Data {
        Data(bytes)
    }
}

package struct MojoRuntimeByteReader: Sendable {
    private let bytes: [UInt8]
    private var offset: Int

    package init(data: Data) {
        self.bytes = Array(data)
        self.offset = 0
    }

    package var remainingCount: Int {
        bytes.count - offset
    }

    package mutating func readUInt8() throws -> UInt8 {
        guard offset < bytes.count else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: 1,
                actual: remainingCount
            )
        }
        let value = bytes[offset]
        offset += 1
        return value
    }

    package mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try readUInt8())
        let b1 = UInt16(try readUInt8())
        return b0 | (b1 << 8)
    }

    package mutating func readUInt32() throws -> UInt32 {
        var value: UInt32 = 0
        for shift in stride(from: 0, through: 24, by: 8) {
            value |= UInt32(try readUInt8()) << UInt32(shift)
        }
        return value
    }

    package mutating func readUInt64() throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 56, by: 8) {
            value |= UInt64(try readUInt8()) << UInt64(shift)
        }
        return value
    }

    package mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    package mutating func readFloat32() throws -> Float32 {
        Float32(bitPattern: try readUInt32())
    }

    package mutating func readBytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else {
            throw MojoRuntimeProtocolError.integerOverflow(
                operation: "negative byte count"
            )
        }
        let end: Int
        guard !count.addingReportingOverflow(offset).overflow else {
            throw MojoRuntimeProtocolError.integerOverflow(
                operation: "reader offset"
            )
        }
        end = offset + count
        guard end <= bytes.count else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: count,
                actual: remainingCount
            )
        }
        let result = Array(bytes[offset..<end])
        offset = end
        return result
    }

    package mutating func readLengthPrefixedString(
        maximumByteCount: Int
    ) throws -> String {
        guard maximumByteCount >= 0 else {
            throw MojoRuntimeProtocolError.invalidLimit
        }
        let length = Int(try readUInt16())
        guard length <= maximumByteCount else {
            throw MojoRuntimeProtocolError.payloadTooLarge(
                length: UInt64(length),
                limit: UInt64(maximumByteCount)
            )
        }
        let data = Data(try readBytes(count: length))
        guard let value = String(data: data, encoding: .utf8) else {
            throw MojoRuntimeProtocolError.invalidUTF8
        }
        return value
    }
}

package enum MojoRuntimeCheckedArithmetic {
    package static func int(_ value: UInt64, label: String) throws -> Int {
        guard let result = Int(exactly: value) else {
            throw MojoRuntimeProtocolError.integerOverflow(operation: label)
        }
        return result
    }

    package static func add(
        _ lhs: Int,
        _ rhs: Int,
        label: String
    ) throws -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else {
            throw MojoRuntimeProtocolError.integerOverflow(operation: label)
        }
        return result
    }

    package static func multiply(
        _ lhs: Int,
        _ rhs: Int,
        label: String
    ) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else {
            throw MojoRuntimeProtocolError.integerOverflow(operation: label)
        }
        return result
    }
}
