import Foundation
import Testing
import MojoRuntimeProtocolCore
import CMojoResourceProtocolReference

@Suite("Resource invocation codec", .timeLimit(.minutes(1)))
struct MojoRuntimeResourceCodecTests {
    private let schema = Array(UInt8(0)..<UInt8(32))

    @Test func fixedSchemaIdentity() {
        #expect(MojoRuntimeResourceProtocol.version == 2)
        #expect(MojoRuntimeResourceProtocol.schemaDigest == "261312b9cf7d85b748c2199187b7f701ab9aa9e585592bb8e0c1fc64b98e1246")
        #expect(MojoRuntimeResourceProtocol.schemaDigest != MojoRuntimeProtocol.schemaDigest)
    }

    @Test func differentialNativeInvocationDecoder() throws {
        for storage in [MojoRuntimeBufferStorageKind.dmaBuf, .copied] {
            let value = try MojoRuntimeResourceInvocation(
                bindingID: 7, argumentSchema: schema, arguments: Data([1,2,3,4]),
                inputs: [input(storage: storage)],
                outputs: [.init(element: .float32, maximumElementCount: 16)], limits: limits()
            )
            let original = Array(value.encodedControl())
            var cases = [original]
            for index in original.indices {
                for byte: UInt8 in [0, 1, 127, 255] {
                    var changed = original
                    changed[index] = byte
                    cases.append(changed)
                }
                cases.append(Array(original.prefix(index)))
            }
            for bytes in cases {
                var copied: UInt64 = 0
                var mapped: UInt64 = 0
                let accepted = bytes.withUnsafeBufferPointer {
                    swmo_reference_invocation($0.baseAddress, $0.count, &copied, &mapped) == 1
                }
                do {
                    let decoded = try MojoRuntimeResourceInvocation.decodeControl(Data(bytes), limits: limits())
                    #expect(accepted)
                    #expect(decoded.copiedBodyByteCount == copied)
                    #expect(decoded.mappedByteCount == mapped)
                } catch {
                    #expect(!accepted)
                }
            }
        }
    }

    private func limits() throws -> MojoRuntimeResourceLimits {
        try MojoRuntimeResourceLimits(
            buffer: .init(maximumRank: 4, maximumRegionByteCount: 8_000_000, allowsEmpty: true),
            maximumInputs: 4, maximumOutputs: 4, maximumArgumentBytes: 64,
            maximumResultValueBytes: 64,
            maximumControlBytes: 1024, maximumCopiedBytes: 8_000_000,
            maximumMappedBytes: 8_000_000, maximumResultBytes: 1024
        )
    }

    private func input(
        ordinal: UInt32 = 0, bytes: UInt64 = 4_147_200,
        storage: MojoRuntimeBufferStorageKind = .dmaBuf
    ) throws -> MojoRuntimeBufferDescriptor {
        try MojoRuntimeBufferDescriptor(
            storage: storage, element: .uint16,
            handleOrdinal: storage == .copied ? UInt32.max : ordinal,
            regionByteCount: bytes, viewByteOffset: 0, payloadOffset: 0,
            dimensions: [2,3], byteStrides: [8,2], limits: limits().buffer
        )
    }

    @Test func sharedInvocationCarriesMetadataOnly() throws {
        let capacity = try MojoRuntimeOutputCapacity(element: .float32, maximumElementCount: 16)
        let value = try MojoRuntimeResourceInvocation(
            bindingID: 7, argumentSchema: schema, arguments: Data([1,2,3,4]),
            inputs: [input()], outputs: [capacity], limits: limits()
        )
        #expect(value.controlByteCount == 48 + 72 + 12 + 4)
        #expect(value.copiedBodyByteCount == 0)
        #expect(value.mappedByteCount == 4_147_200)
        #expect(value.sharedHandleCount == 1)
        let bytes = value.encodedControl()
        #expect(Array(bytes.prefix(8)) == [7,0,0,0,0,0,0,0])
        #expect(Array(bytes[8..<40]) == schema)
        #expect(Array(bytes[40..<48]) == [4,0,0,0,1,0,1,0])
        #expect(try MojoRuntimeResourceInvocation.decodeControl(bytes, limits: limits()) == value)
        for count in 0..<bytes.count {
            #expect(throws: (any Error).self) {
                try MojoRuntimeResourceInvocation.decodeControl(Data(bytes.prefix(count)), limits: limits())
            }
        }
        #expect(throws: (any Error).self) {
            try MojoRuntimeResourceInvocation.decodeControl(bytes + Data([0]), limits: limits())
        }
    }

    @Test func sharedAliasesDoNotDoubleCountAndCannotChangeRegion() throws {
        let view = try input()
        let value = try MojoRuntimeResourceInvocation(
            bindingID: 1, argumentSchema: schema, arguments: Data(),
            inputs: [view, view], outputs: [], limits: limits()
        )
        #expect(value.sharedHandleCount == 1 && value.mappedByteCount == view.regionByteCount)
        #expect(throws: MojoRuntimeBufferError.inconsistentSharedRegion) {
            try MojoRuntimeResourceInvocation(
                bindingID: 1, argumentSchema: schema, arguments: Data(),
                inputs: [view, input(bytes: 14)], outputs: [], limits: limits()
            )
        }
        #expect(throws: MojoRuntimeBufferError.invalidHandleOrdinal) {
            try MojoRuntimeResourceInvocation(
                bindingID: 1, argumentSchema: schema, arguments: Data(),
                inputs: [input(ordinal: 1)], outputs: [], limits: limits()
            )
        }
        #expect(throws: MojoRuntimeBufferError.aggregateLimitExceeded) {
            try MojoRuntimeResourceInvocation(
                bindingID: 1, argumentSchema: schema, arguments: Data(),
                inputs: [view, input(ordinal: 1)], outputs: [], limits: limits()
            )
        }
    }

    @Test func copiedStorageIsExplicitAndAccountsWholeRegion() throws {
        let value = try MojoRuntimeResourceInvocation(
            bindingID: 1, argumentSchema: schema, arguments: Data(),
            inputs: [input(storage: .copied)], outputs: [], limits: limits()
        )
        #expect(value.sharedHandleCount == 0 && value.mappedByteCount == 0)
        #expect(value.copiedBodyByteCount == 4_147_200)
        #expect(value.encodedControl().count == 120)
    }

    @Test func limitsApplyAgainAtInvocationAdmission() throws {
        let broad = try MojoRuntimeBufferLimits(maximumRank: 8, maximumRegionByteCount: 100, allowsEmpty: true)
        let view = try MojoRuntimeBufferDescriptor(
            storage: .sharedFile, element: .uint8, handleOrdinal: 0,
            regionByteCount: 1, viewByteOffset: 0, payloadOffset: 0,
            dimensions: [1,1,1,1,1], byteStrides: [1,1,1,1,1], limits: broad
        )
        #expect(throws: MojoRuntimeBufferError.rankLimitExceeded) {
            try MojoRuntimeResourceInvocation(
                bindingID: 1, argumentSchema: schema, arguments: Data(),
                inputs: [view], outputs: [], limits: limits()
            )
        }
        #expect(throws: MojoRuntimeBufferError.invalidBinding) {
            try MojoRuntimeResourceInvocation(bindingID: 0, argumentSchema: schema, arguments: Data(), inputs: [], outputs: [], limits: limits())
        }
        #expect(throws: MojoRuntimeBufferError.invalidSchema) {
            try MojoRuntimeResourceInvocation(bindingID: 1, argumentSchema: [0], arguments: Data(), inputs: [], outputs: [], limits: limits())
        }
    }

    @Test func terminalResultPairsSchemaAndCapacity() throws {
        let capacity = try MojoRuntimeOutputCapacity(element: .float64, maximumElementCount: 10)
        let value = try MojoRuntimeResourceResult(
            status: 0, outputSchema: schema, values: Data([9]), elementCounts: [3],
            expectedSchema: schema, capacities: [capacity], limits: limits()
        )
        #expect(value.bodyByteCount == 24)
        let encoded = value.encodedControl()
        #expect(encoded.count == 53)
        #expect(Array(encoded[36..<44]) == [1,0,0,0,1,0,0,0])
        #expect(try MojoRuntimeResourceResult.decodeControl(encoded, expectedSchema: schema, capacities: [capacity], limits: limits()) == value)
        for count in 0..<encoded.count {
            #expect(throws: (any Error).self) {
                try MojoRuntimeResourceResult.decodeControl(Data(encoded.prefix(count)), expectedSchema: schema, capacities: [capacity], limits: limits())
            }
        }
        #expect(throws: MojoRuntimeBufferError.invalidSchema) {
            try MojoRuntimeResourceResult.decodeControl(encoded, expectedSchema: Array(repeating: 0, count: 32), capacities: [capacity], limits: limits())
        }
        #expect(throws: MojoRuntimeBufferError.countLimitExceeded) {
            try MojoRuntimeResourceResult(status: 0, outputSchema: schema, values: Data(), elementCounts: [11], expectedSchema: schema, capacities: [capacity], limits: limits())
        }
        #expect(throws: MojoRuntimeBufferError.resultCountMismatch) {
            try MojoRuntimeResourceResult(status: 0, outputSchema: schema, values: Data(), elementCounts: [], expectedSchema: schema, capacities: [capacity], limits: limits())
        }
    }

    @Test func failureNeverPublishesOutput() throws {
        let failure = try MojoRuntimeResourceResult(status: -8, outputSchema: schema, values: Data(), elementCounts: [], expectedSchema: schema, capacities: [], limits: limits())
        #expect(failure.bodyByteCount == 0)
        #expect(throws: MojoRuntimeBufferError.failedResultHasOutput) {
            try MojoRuntimeResourceResult(status: -8, outputSchema: schema, values: Data([1]), elementCounts: [], expectedSchema: schema, capacities: [], limits: limits())
        }
        #expect(throws: MojoRuntimeBufferError.failedResultHasOutput) {
            try MojoRuntimeResourceResult(status: -8, outputSchema: schema, values: Data(), elementCounts: [0], expectedSchema: schema, capacities: [], limits: limits())
        }
    }

    @Test func differentialNativeResultDecoder() throws {
        let capacity = try MojoRuntimeOutputCapacity(element: .float64, maximumElementCount: 10)
        for status: Int32 in [0, -8] {
            let value = try MojoRuntimeResourceResult(
                status: status, outputSchema: schema,
                values: status == 0 ? Data([1,2,3]) : Data(),
                elementCounts: status == 0 ? [3] : [], expectedSchema: schema,
                capacities: [capacity], limits: limits()
            )
            let original = Array(value.encodedControl())
            var cases = [original]
            for index in original.indices {
                for byte: UInt8 in [0,1,127,255] {
                    var changed = original
                    changed[index] = byte
                    cases.append(changed)
                }
                cases.append(Array(original.prefix(index)))
            }
            for bytes in cases {
                var body: UInt64 = 0
                let accepted = bytes.withUnsafeBufferPointer {
                    swmo_reference_result($0.baseAddress, $0.count, &body) == 1
                }
                do {
                    let decoded = try MojoRuntimeResourceResult.decodeControl(Data(bytes), expectedSchema: schema, capacities: [capacity], limits: limits())
                    #expect(accepted)
                    #expect(decoded.bodyByteCount == body)
                } catch {
                    #expect(!accepted)
                }
            }
        }
    }

    @Test func reservesResultMetadataBeforeInvocation() throws {
        #expect(throws: MojoRuntimeBufferError.aggregateLimitExceeded) {
            try MojoRuntimeResourceInvocation(
                bindingID: 1, argumentSchema: schema, arguments: Data(), inputs: [],
                outputs: [.init(element: .uint8, maximumElementCount: 1024)], limits: limits()
            )
        }
        #expect(throws: MojoRuntimeBufferError.countLimitExceeded) {
            try MojoRuntimeResourceResult(
                status: 0, outputSchema: schema, values: Data(repeating: 0, count: 65),
                elementCounts: [], expectedSchema: schema, capacities: [], limits: limits()
            )
        }
    }
}
