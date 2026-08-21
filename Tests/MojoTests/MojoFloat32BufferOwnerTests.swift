import Foundation
@_spi(SwiftMojoGenerated) import Mojo
import Synchronization
import Testing

@Suite("Mojo Float32 buffer ownership")
struct MojoFloat32BufferOwnerTests {
    @Test(.timeLimit(.minutes(1)))
    func ownsMetadataAndDestroysBeforeTheSession() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)
        let buffer = try makeBuffer(session: session, recorder: recorder)

        #expect(buffer.elementCount == 8)
        #expect(buffer.byteCount == 32)
        #expect(buffer.device == .cpu)
        #expect(buffer.memoryKind == .host)
        #expect(throws: MojoSessionError.activeResources(1)) {
            try session.shutdown()
        }

        try buffer.shutdown()
        try session.shutdown()
        try buffer.shutdown()
        #expect(recorder.bufferDestructionCount == 1)
        #expect(recorder.sessionDestructionCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnavailableMemoryBeforeCreatingAResource() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)
        let required: MojoSessionCapability = [
            .synchronousInvocation,
            .float32,
            .deviceMemory,
        ]
        let available = session.capabilities.availableCapabilities

        #expect(
            throws: MojoBufferError.missingCapabilities(
                required: required,
                available: available
            )
        ) {
            _ = try MojoFloat32BufferOwner.create(
                session: session,
                expectedSessionDomainID: 31,
                elementCount: 8,
                memoryKind: .device,
                create: { _, _ in
                    recorder.recordCreation()
                    return UnsafeMutableRawPointer.allocate(
                        byteCount: 1,
                        alignment: 1
                    )
                },
                destroy: { _, resource in
                    recorder.destroyBuffer(resource)
                },
                copyFromHost: { _, _, _, _ in },
                copyToHost: { _, _, _, _ in }
            )
        }
        #expect(recorder.creationCount == 0)
        #expect(recorder.bufferDestructionCount == 0)
        try session.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsByteCountOverflowBeforeCreatingAResource() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)

        #expect(
            throws: MojoBufferError.sizeOverflow(
                elementCount: UInt64.max,
                elementStride: 4
            )
        ) {
            _ = try MojoFloat32BufferOwner.create(
                session: session,
                expectedSessionDomainID: 31,
                elementCount: UInt64.max,
                memoryKind: .host,
                create: { _, _ in
                    recorder.recordCreation()
                    return UnsafeMutableRawPointer.allocate(
                        byteCount: 1,
                        alignment: 1
                    )
                },
                destroy: { _, resource in
                    recorder.destroyBuffer(resource)
                },
                copyFromHost: { _, _, _, _ in },
                copyToHost: { _, _, _, _ in }
            )
        }
        #expect(recorder.creationCount == 0)
        try session.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsSessionWithoutSynchronousInvocation() throws {
        let recorder = BufferFixtureRecorder()
        let handle = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        let session = MojoSessionOwner(
            handle: handle,
            sessionDomainID: 31,
            capabilities: MojoSessionCapabilities(
                device: .cpu,
                ordinal: 0,
                availableCapabilities: [
                    .hostAccessibleMemory,
                    .float32,
                ]
            ),
            destroy: { session in
                recorder.destroySession(session)
            }
        )
        let required: MojoSessionCapability = [
            .synchronousInvocation,
            .hostAccessibleMemory,
            .float32,
        ]

        #expect(
            throws: MojoBufferError.missingCapabilities(
                required: required,
                available: [.hostAccessibleMemory, .float32]
            )
        ) {
            _ = try MojoFloat32BufferOwner.create(
                session: session,
                expectedSessionDomainID: 31,
                elementCount: 8,
                memoryKind: .host,
                create: { _, _ in
                    recorder.recordCreation()
                    return UnsafeMutableRawPointer.allocate(
                        byteCount: 1,
                        alignment: 1
                    )
                },
                destroy: { _, resource in
                    recorder.destroyBuffer(resource)
                },
                copyFromHost: { _, _, _, _ in },
                copyToHost: { _, _, _, _ in }
            )
        }
        #expect(recorder.creationCount == 0)
        try session.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func copiesHostValuesThroughTheOwnedResource() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)
        let buffer = try makeBuffer(session: session, recorder: recorder)
        let source: [Float] = [1, 2, 3, 4, 5, 6, 7, 8]
        var destination = [Float](repeating: 0, count: source.count)

        try buffer.copy(from: source)
        try buffer.copy(into: &destination)

        #expect(destination == source)
        try buffer.shutdown()
        #expect(throws: MojoSessionError.resourceShutdown) {
            try buffer.copy(from: source)
        }
        try session.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsHostBufferCountMismatchBeforeBorrowingTheResource() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)
        let buffer = try makeBuffer(session: session, recorder: recorder)
        var destination = [Float](repeating: 0, count: 7)

        #expect(
            throws: MojoBufferError.elementCountMismatch(
                expected: 8,
                actual: 7
            )
        ) {
            try buffer.copy(from: destination)
        }
        #expect(
            throws: MojoBufferError.elementCountMismatch(
                expected: 8,
                actual: 7
            )
        ) {
            try buffer.copy(into: &destination)
        }

        try buffer.shutdown()
        try session.shutdown()
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsZeroElementBufferBeforeCreatingAResource() throws {
        let recorder = BufferFixtureRecorder()
        let session = makeSession(recorder: recorder)

        #expect(throws: MojoBufferError.zeroElementCountUnsupported) {
            _ = try MojoFloat32BufferOwner.create(
                session: session,
                expectedSessionDomainID: 31,
                elementCount: 0,
                memoryKind: .host,
                create: { _, _ in
                    recorder.recordCreation()
                    return UnsafeMutableRawPointer.allocate(
                        byteCount: 1,
                        alignment: 1
                    )
                },
                destroy: { _, resource in
                    recorder.destroyBuffer(resource)
                },
                copyFromHost: { _, _, _, _ in },
                copyToHost: { _, _, _, _ in }
            )
        }
        #expect(recorder.creationCount == 0)
        try session.shutdown()
    }

    private func makeSession(
        recorder: BufferFixtureRecorder
    ) -> MojoSessionOwner {
        let handle = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        return MojoSessionOwner(
            handle: handle,
            sessionDomainID: 31,
            capabilities: MojoSessionCapabilities(
                device: .cpu,
                ordinal: 0,
                availableCapabilities: [
                    .synchronousInvocation,
                    .hostAccessibleMemory,
                    .float32,
                ]
            ),
            destroy: { session in
                recorder.destroySession(session)
            }
        )
    }

    private func makeBuffer(
        session: MojoSessionOwner,
        recorder: BufferFixtureRecorder
    ) throws -> MojoFloat32BufferOwner {
        try MojoFloat32BufferOwner.create(
            session: session,
            expectedSessionDomainID: 31,
            elementCount: 8,
            memoryKind: .host,
            create: { _, _ in
                recorder.recordCreation()
                return UnsafeMutableRawPointer.allocate(
                    byteCount: 8 * MemoryLayout<Float>.stride,
                    alignment: MemoryLayout<Float>.alignment
                )
            },
            destroy: { _, resource in
                recorder.destroyBuffer(resource)
            },
            copyFromHost: { _, resource, source, count in
                resource.copyMemory(
                    from: UnsafeRawPointer(source),
                    byteCount: Int(count) * MemoryLayout<Float>.stride
                )
            },
            copyToHost: { _, resource, destination, count in
                UnsafeMutableRawPointer(destination).copyMemory(
                    from: UnsafeRawPointer(resource),
                    byteCount: Int(count) * MemoryLayout<Float>.stride
                )
            }
        )
    }
}

private final class BufferFixtureRecorder: Sendable {
    private struct State: Sendable {
        var creationCount = 0
        var bufferDestructionCount = 0
        var sessionDestructionCount = 0
    }

    private let state = Mutex(State())

    var creationCount: Int {
        state.withLock { $0.creationCount }
    }

    var bufferDestructionCount: Int {
        state.withLock { $0.bufferDestructionCount }
    }

    var sessionDestructionCount: Int {
        state.withLock { $0.sessionDestructionCount }
    }

    func recordCreation() {
        state.withLock { $0.creationCount += 1 }
    }

    func destroyBuffer(_ resource: UnsafeMutableRawPointer) {
        state.withLock { $0.bufferDestructionCount += 1 }
        resource.deallocate()
    }

    func destroySession(_ session: UnsafeMutableRawPointer) {
        state.withLock { $0.sessionDestructionCount += 1 }
        session.deallocate()
    }
}
