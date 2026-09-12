import Foundation
import Testing
import MojoRuntimeProtocolCore
import CMojoResourceProtocolReference

@Suite("Resource buffer layout", .timeLimit(.minutes(1)))
struct MojoRuntimeBufferDescriptorTests {
    private func limits(empty: Bool = false) throws -> MojoRuntimeBufferLimits {
        try MojoRuntimeBufferLimits(
            maximumRank: 4, maximumRegionByteCount: UInt64(Int.max),
            allowsEmpty: empty
        )
    }

    @Test func differentialNativeCDecoder() throws {
        var writer = MojoRuntimeByteWriter()
        try view().encode(into: &writer)
        var cases = [writer.bytes]
        // Every single-byte substitution probes header enums, reserved fields,
        // all extent words, truncation and dimensions against independent C.
        for index in writer.bytes.indices {
            for value: UInt8 in [0, 1, 127, 255] {
                var bytes = writer.bytes
                bytes[index] = value
                cases.append(bytes)
            }
            cases.append(Array(writer.bytes.prefix(index)))
        }
        for bytes in cases {
            var nativeEnd: UInt64 = 0
            let accepted = bytes.withUnsafeBufferPointer {
                swmo_reference_buffer_end($0.baseAddress, $0.count, 4, UInt64(Int.max), 1, &nativeEnd) == 1
            }
            var reader = MojoRuntimeByteReader(data: Data(bytes))
            do {
                let decoded = try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: limits(empty: true))
                #expect(accepted)
                #expect(decoded.addressedByteEnd == nativeEnd)
            } catch {
                #expect(!accepted)
            }
        }
    }

    private func view(
        dimensions: [UInt64] = [2, 3], strides: [UInt64] = [8, 2],
        bytes: UInt64 = 14, offset: UInt64 = 0, empty: Bool = false
    ) throws -> MojoRuntimeBufferDescriptor {
        try MojoRuntimeBufferDescriptor(
            storage: .sharedFile, element: .uint16, handleOrdinal: 0,
            regionByteCount: bytes, viewByteOffset: offset, payloadOffset: 0,
            dimensions: dimensions, byteStrides: strides, limits: limits(empty: empty)
        )
    }

    @Test func stridedExtentAndGoldenBytes() throws {
        let value = try view()
        #expect(value.addressedByteEnd == 14)
        var writer = MojoRuntimeByteWriter()
        value.encode(into: &writer)
        // Independently laid out canonical descriptor: readonly shared UInt16,
        // rank two, region 14, offset zero, dimensions/strides (2,8), (3,2).
        let expected: [UInt8] = [
            2,0, 4,0, 2,0, 0,0, 0,0,0,0, 0,0,0,0,
            14,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
            0,0,0,0,0,0,0,0,
            2,0,0,0,0,0,0,0, 8,0,0,0,0,0,0,0,
            3,0,0,0,0,0,0,0, 2,0,0,0,0,0,0,0,
        ]
        #expect(writer.bytes == expected)
        var reader = MojoRuntimeByteReader(data: Data(expected))
        #expect(try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: limits()) == value)
        #expect(reader.remainingCount == 0)
    }

    @Test func rejectsOutOfBoundsOverflowAndAlignment() throws {
        #expect(throws: MojoRuntimeBufferError.extentOutOfBounds) { try view(bytes: 13) }
        #expect(throws: MojoRuntimeBufferError.extentOverflow) {
            try view(dimensions: [UInt64.max], strides: [2], bytes: UInt64(Int.max))
        }
        #expect(throws: MojoRuntimeBufferError.extentOverflow) {
            try view(dimensions: [2, 2], strides: [UInt64.max - 1, 2], bytes: UInt64(Int.max))
        }
        #expect(throws: MojoRuntimeBufferError.unalignedView) { try view(offset: 1) }
        #expect(throws: MojoRuntimeBufferError.unalignedView) { try view(strides: [7, 2]) }
        #expect(throws: MojoRuntimeBufferError.invalidStride) { try view(strides: [0, 2]) }
        #expect(throws: MojoRuntimeBufferError.rankMismatch) { try view(strides: [2]) }
        #expect(throws: MojoRuntimeBufferError.rankLimitExceeded) {
            try view(dimensions: [1,1,1,1,1], strides: [2,2,2,2,2])
        }
    }

    @Test func emptyAndScalarSemantics() throws {
        #expect(throws: MojoRuntimeBufferError.emptyNotAllowed) {
            try view(dimensions: [0, UInt64.max], strides: [0, UInt64.max], bytes: 0)
        }
        let empty = try view(dimensions: [0, UInt64.max], strides: [0, UInt64.max], bytes: 0, empty: true)
        #expect(empty.isEmpty && empty.addressedByteEnd == 0)
        #expect(throws: MojoRuntimeBufferError.extentOutOfBounds) {
            try view(dimensions: [0], strides: [0], bytes: 0, offset: 2, empty: true)
        }
        let scalar = try view(dimensions: [], strides: [], bytes: 2)
        #expect(!scalar.isEmpty && scalar.addressedByteEnd == 2)
        #expect(throws: MojoRuntimeBufferError.extentOutOfBounds) {
            try view(dimensions: [], strides: [], bytes: 0, empty: true)
        }
    }

    @Test func everyElementWidthAndOverlappingReadViews() throws {
        let widths: [UInt64] = [1,1,2,2,4,4,8,8,2,4,8]
        for (index, element) in MojoRuntimeElementType.allCases.enumerated() {
            #expect(element.rawValue == index + 1)
            #expect(element.byteWidth == widths[index])
            let value = try MojoRuntimeBufferDescriptor(
                storage: .copied, element: element, handleOrdinal: UInt32.max,
                regionByteCount: widths[index], viewByteOffset: 0,
                payloadOffset: 0, dimensions: [], byteStrides: [], limits: limits()
            )
            #expect(value.addressedByteEnd == widths[index])
        }
        #expect(try view(strides: [2,2], bytes: 8).addressedByteEnd == 8)
    }

    @Test func malformedWireAndEveryTruncationFail() throws {
        var writer = MojoRuntimeByteWriter()
        try view().encode(into: &writer)
        for length in 0..<writer.bytes.count {
            var reader = MojoRuntimeByteReader(data: Data(writer.bytes.prefix(length)))
            #expect(throws: (any Error).self) {
                try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: limits())
            }
        }
        for (offset, byte) in [(0,UInt8(99)), (2,99), (4,5), (6,1), (12,1), (32,1)] {
            var malformed = writer.bytes
            malformed[offset] = byte
            var reader = MojoRuntimeByteReader(data: Data(malformed))
            #expect(throws: (any Error).self) {
                try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: limits())
            }
        }
        var invalidOrdinal = writer.bytes
        for index in 8..<12 { invalidOrdinal[index] = 255 }
        var reader = MojoRuntimeByteReader(data: Data(invalidOrdinal))
        #expect(throws: MojoRuntimeBufferError.invalidHandleOrdinal) {
            try MojoRuntimeBufferDescriptor.decode(from: &reader, limits: limits())
        }
    }

    @Test func mappedAndWireLimitsAreIndependent() throws {
        #expect(throws: MojoRuntimeBufferError.invalidLimits) {
            try MojoRuntimeBufferLimits(maximumRank: 1, maximumRegionByteCount: UInt64.max, allowsEmpty: false)
        }
        let small = try MojoRuntimeBufferLimits(maximumRank: 2, maximumRegionByteCount: 12, allowsEmpty: false)
        #expect(throws: MojoRuntimeBufferError.regionLimitExceeded) {
            try MojoRuntimeBufferDescriptor(
                storage: .dmaBuf, element: .uint16, handleOrdinal: 0,
                regionByteCount: 14, viewByteOffset: 0, payloadOffset: 0,
                dimensions: [2,3], byteStrides: [8,2], limits: small
            )
        }
        // A complete descriptor consumes metadata only, independent of input bytes.
        let frame = try view(dimensions: [1080,1920], strides: [3840,2], bytes: 4_147_200)
        var writer = MojoRuntimeByteWriter()
        frame.encode(into: &writer)
        #expect(writer.bytes.count == 72)
    }
}
