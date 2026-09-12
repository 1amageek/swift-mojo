import Foundation
import MojoRuntimeWorker
import Synchronization
import Testing

@Suite("Mojo input buffer views")
struct MojoBufferViewTests {
    @Test
    func paddedSubviewRetainsOriginalOwnerWithoutBorrowingOrRepacking() throws {
        let source = ViewSource()
        let owner = try MojoReadOnlyBuffer(hostSource: source)
        let view = try MojoBufferView(
            buffer: owner, elementType: .uint16, byteOffset: 2,
            dimensions: [2, 3], byteStrides: [16, 2]
        )
        #expect(view.buffer === owner)
        #expect(view.buffer.byteCount == 32)
        #expect(view.byteOffset == 2)
        #expect(view.byteStrides == [16, 2])
        #expect(view.elementType.byteWidth == 2)
        #expect(source.borrows.withLock { $0 } == 0)
        let overlapping = try MojoBufferView(
            buffer: owner, elementType: .uint16,
            dimensions: [2, 2], byteStrides: [2, 2]
        )
        #expect(overlapping.buffer === view.buffer)
        #expect(source.borrows.withLock { $0 } == 0)
    }

    @Test
    func actualOwnerExtentRejectsInvalidSubviewBeforeAccess() throws {
        let source = ViewSource()
        let owner = try MojoReadOnlyBuffer(hostSource: source)
        #expect(throws: MojoInputBufferError.invalidLayout(diagnostic: "extentOutOfBounds")) {
            try MojoBufferView(
                buffer: owner, elementType: .uint16, byteOffset: 2,
                dimensions: [3, 3], byteStrides: [16, 2]
            )
        }
        #expect(throws: MojoInputBufferError.invalidLayout(diagnostic: "extentOverflow")) {
            try MojoBufferView(
                buffer: owner, elementType: .uint8,
                dimensions: [UInt64.max], byteStrides: [UInt64.max]
            )
        }
        #expect(source.borrows.withLock { $0 } == 0)
    }
}

private final class ViewSource: MojoBufferSource {
    let byteCount = 32
    let borrows = Mutex(0)
    private let data = Data(repeating: 0, count: 32)
    func withUnsafeBytes<Result>(
        _ body: (UnsafeRawBufferPointer) throws -> Result
    ) rethrows -> Result {
        borrows.withLock { $0 += 1 }
        return try data.withUnsafeBytes(body)
    }
}
