import Foundation
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Canonical scalar invocation arguments")
struct MojoInvocationArgumentsTests {
    @Test
    func everyNumericWidthHasAnExactLittleEndianRepresentation() throws {
        let arguments = try MojoInvocationArguments([
            .int8(-1), .uint8(0x80), .int16(.min), .uint16(0x1234),
            .int32(.min), .uint32(0x12345678), .int64(.min), .uint64(.max),
            .float16(Float16(bitPattern: 0x7e01)),
            .float32(Float(bitPattern: 0x80000000)),
            .float64(Double(bitPattern: 0x7ff8000000000001)),
        ])
        let expected: [UInt8] = [
            0xff, 0x80, 0, 0x80, 0x34, 0x12,
            0, 0, 0, 0x80, 0x78, 0x56, 0x34, 0x12,
            0, 0, 0, 0, 0, 0, 0, 0x80,
            0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
            0x01, 0x7e, 0, 0, 0, 0x80,
            1, 0, 0, 0, 0, 0, 0xf8, 0x7f,
        ]
        #expect(arguments.byteCount == expected.count)
        #expect(try arguments.encoded(expectedSchema: arguments.schema,
                                      maximumBytes: UInt32(expected.count)) == Data(expected))
        // Computed independently with Python hashlib over the documented record.
        #expect(arguments.schema.map { String(format: "%02x", $0) }.joined()
                == "46356965e6b188980f0242a4a05b7e0e7fa621e7cd336b222b413702c165198e")
    }

    @Test
    func schemaDependsOnTypesAndOrderAndRejectsUnadmittedRecords() throws {
        let first = try MojoInvocationArguments([.uint16(1), .float32(2)])
        let other = try MojoInvocationArguments([.uint16(9), .float32(10)])
        let reversed = try MojoInvocationArguments([.float32(2), .uint16(1)])
        #expect(first.schema == other.schema)
        #expect(first.schema != reversed.schema)
        #expect(throws: MojoInvocationArgumentError.schemaMismatch) {
            try first.encoded(expectedSchema: reversed.schema, maximumBytes: 6)
        }
        #expect(throws: MojoInvocationArgumentError.byteLimitExceeded) {
            try first.encoded(expectedSchema: first.schema, maximumBytes: 5)
        }
        #expect(throws: MojoInvocationArgumentError.tooManyValues) {
            try MojoInvocationArguments(Array(repeating: .uint8(0), count: 65536))
        }
        let empty = try MojoInvocationArguments([])
        #expect(try empty.encoded(expectedSchema: empty.schema, maximumBytes: 0).isEmpty)
    }
}
