import Foundation
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Resource binding signature admission")
struct MojoRuntimeResourceSignatureTests {
    @Test
    func canonicalSignatureIncludesEveryOrderedTypeAndRank() throws {
        let signature = try MojoRuntimeResourceSignature(
            arguments: [.uint32, .float64], inputs: [.init(element: .uint16, rank: 2)],
            results: [.int32], outputs: [.float32, .uint8]
        )
        #expect(signature.encoded == Data([
            2, 0, 1, 0, 1, 0, 2, 0,
            6, 0, 11, 0, 4, 0, 2, 0, 5, 0, 10, 0, 2, 0,
        ]))
        #expect(signature.argumentByteCount == 12)
        #expect(signature.resultByteCount == 4)
        #expect(signature.argumentSchema != signature.resultSchema)
    }

    @Test(arguments: [0, 1, 2, 3])
    func rejectsWrongInputTypeRankCountOrOutputType(mutation: Int) throws {
        let signature = try MojoRuntimeResourceSignature(
            arguments: [], inputs: [.init(element: .uint16, rank: 1)],
            results: [], outputs: [.float32]
        )
        let input = try MojoBufferView(
            buffer: MojoReadOnlyBuffer(hostSource: Data(count: 8)),
            elementType: mutation == 0 ? .int16 : .uint16,
            dimensions: mutation == 1 ? [2, 2] : [4],
            byteStrides: mutation == 1 ? [4, 2] : [2]
        )
        let limits = try MojoRuntimeResourceLimits(
            buffer: MojoRuntimeBufferLimits(maximumRank: 2,
                                           maximumRegionByteCount: 64, allowsEmpty: false),
            maximumInputs: 2, maximumOutputs: 1,
            maximumArgumentBytes: 8, maximumResultValueBytes: 8,
            maximumControlBytes: 4096, maximumCopiedBytes: 64,
            maximumMappedBytes: 64, maximumResultBytes: 128
        )
        let outputs = [try MojoRuntimeOutputCapacity(
            element: mutation == 3 ? .uint32 : .float32, maximumElementCount: 1
        )]
        #expect(throws: MojoRuntimeBufferError.invalidBinding) {
            try MojoRuntimePreparedInvocation(
                bindingID: 7, signature: signature, arguments: MojoInvocationArguments([]),
                inputs: mutation == 2 ? [input, input] : [input],
                outputs: outputs, limits: limits
            )
        }
        // A wire receiver rejects the same type mismatches independently of Swift views.
        let descriptor = try MojoRuntimeBufferDescriptor(
            storage: .copied, element: input.elementType.wireType,
            handleOrdinal: UInt32.max, regionByteCount: 8, viewByteOffset: 0,
            payloadOffset: 0, dimensions: input.dimensions, byteStrides: input.byteStrides,
            limits: limits.buffer
        )
        let request = try MojoRuntimeResourceInvocation(
            bindingID: 7, argumentSchema: signature.argumentSchema, arguments: Data(),
            inputs: mutation == 2 ? [descriptor, descriptor] : [descriptor],
            outputs: outputs, limits: limits
        )
        #expect(throws: MojoRuntimeBufferError.invalidBinding) {
            try signature.validate(MojoRuntimeResourceInvocation.decodeControl(
                request.encodedControl(), limits: limits
            ))
        }
    }
}
