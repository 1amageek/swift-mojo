import Foundation
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import MojoRuntimeWorkerPOSIX
import Synchronization
import Testing

@Suite("Resource invocation preparation")
struct MojoRuntimePreparedInvocationTests {
    @Test(.timeLimit(.minutes(1)))
    func nativeAliasesSendOneHandleAndNoInputPayload() throws {
        try withNativeBuffer { native in
            let first = try MojoBufferView(
                buffer: native, elementType: .uint16,
                dimensions: [2, 3], byteStrides: [16, 2]
            )
            let second = try MojoBufferView(
                buffer: native, elementType: .uint8, byteOffset: 2,
                dimensions: [4], byteStrides: [1]
            )
            let prepared = try prepare([first, second])
            #expect(prepared.owners.count == 1)
            #expect(prepared.owners[0] === native)
            #expect(prepared.sharedDescriptors.count == 1)
            #expect(prepared.copiedRegions.isEmpty)
            #expect(prepared.metadata.copiedBodyByteCount == 0)
            #expect(prepared.metadata.mappedByteCount == 64)
            #expect(prepared.retainedByteCount == 64)
            #expect(prepared.metadata.inputs.map(\.handleOrdinal) == [0, 0])
            #expect(try MojoRuntimeResourceInvocation.decodeControl(
                prepared.control, limits: limits()
            ) == prepared.metadata)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mixedRegionsPreserveAlignmentAndNeverBorrowDuringPreparation() throws {
        let firstSource = PreparedSource(count: 3)
        let lastSource = PreparedSource(count: 8)
        let first = try MojoReadOnlyBuffer(hostSource: firstSource)
        let last = try MojoReadOnlyBuffer(hostSource: lastSource)
        try withNativeBuffer { native in
            let views = try [
                MojoBufferView(buffer: first, elementType: .uint8,
                               dimensions: [3], byteStrides: [1]),
                MojoBufferView(buffer: native, elementType: .uint8,
                               dimensions: [64], byteStrides: [1]),
                MojoBufferView(buffer: last, elementType: .uint8,
                               dimensions: [8], byteStrides: [1]),
                MojoBufferView(buffer: last, elementType: .float64,
                               dimensions: [1], byteStrides: [8]),
            ]
            let prepared = try prepare(views)
            #expect(prepared.owners.count == 3)
            #expect(prepared.copiedRegions.map(\.payloadOffset) == [0, 8])
            #expect(prepared.metadata.inputs.map(\.payloadOffset) == [0, 0, 8, 8])
            #expect(prepared.metadata.copiedBodyByteCount == 16)
            #expect(prepared.metadata.mappedByteCount == 64)
            #expect(prepared.retainedByteCount == 75)
            #expect(prepared.sharedDescriptors.count == 1)
            #expect(firstSource.borrows.withLock { $0 } == 0)
            #expect(lastSource.borrows.withLock { $0 } == 0)
        }
    }

    @Test
    func bindingLimitsRevalidateAViewConstructedUnderGeneralLimits() throws {
        let source = PreparedSource(count: 8)
        let view = try MojoBufferView(
            buffer: MojoReadOnlyBuffer(hostSource: source), elementType: .float32,
            dimensions: [2], byteStrides: [4]
        )
        #expect(throws: MojoRuntimeBufferError.regionLimitExceeded) {
            try prepare([view], limits: limits(region: 4))
        }
        #expect(throws: MojoRuntimeBufferError.aggregateLimitExceeded) {
            try prepare([view], limits: limits(copied: 7))
        }
        #expect(throws: MojoRuntimeBufferError.countLimitExceeded) {
            try prepare([view, view], limits: limits(inputs: 1))
        }
        #expect(source.borrows.withLock { $0 } == 0)
    }

    private func prepare(
        _ inputs: [MojoBufferView], limits: MojoRuntimeResourceLimits? = nil
    ) throws -> MojoRuntimePreparedInvocation {
        try MojoRuntimePreparedInvocation(
            bindingID: 7, signature: MojoRuntimeResourceSignature(
                arguments: [.uint8, .uint8],
                inputs: inputs.map { .init(element: $0.elementType.wireType, rank: UInt16($0.dimensions.count)) },
                results: [], outputs: []
            ),
            arguments: MojoInvocationArguments([.uint8(1), .uint8(2)]), inputs: inputs, outputs: [],
            limits: limits ?? self.limits()
        )
    }

    private func limits(
        region: UInt64 = 4096, copied: UInt64 = 4096, inputs: UInt16 = 4
    ) throws -> MojoRuntimeResourceLimits {
        try MojoRuntimeResourceLimits(
            buffer: MojoRuntimeBufferLimits(maximumRank: 3,
                                           maximumRegionByteCount: region, allowsEmpty: false),
            maximumInputs: inputs, maximumOutputs: 2,
            maximumArgumentBytes: 64, maximumResultValueBytes: 64,
            maximumControlBytes: 4096, maximumCopiedBytes: copied,
            maximumMappedBytes: 4096, maximumResultBytes: 4096
        )
    }

    private func withNativeBuffer(_ body: (MojoReadOnlyBuffer) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 3, count: 64).write(to: url)
        defer {
            do { try FileManager.default.removeItem(at: url) }
            catch { Issue.record("Fixture removal failed: \(error)") }
        }
        let file = try FileHandle(forReadingFrom: url)
        defer {
            do { try file.close() }
            catch { Issue.record("Fixture close failed: \(error)") }
        }
        let native = try MojoPOSIXSharedInput.importReadOnly(
            descriptor: file.fileDescriptor, byteCount: 64, retaining: file, kind: .regularFile
        )
        try body(native)
    }
}

private final class PreparedSource: MojoBufferSource {
    let byteCount: Int
    let borrows = Mutex(0)
    private let data: Data
    init(count: Int) { byteCount = count; data = Data(repeating: 0, count: count) }
    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        borrows.withLock { $0 += 1 }
        return try data.withUnsafeBytes(body)
    }
}
