import Foundation
@_spi(SwiftMojoGenerated) import Mojo
import Synchronization
import Testing

@Suite("Mojo session ownership")
struct MojoSessionOwnerTests {
    @Test(.timeLimit(.minutes(1)))
    func explicitShutdownDestroysExactlyOnce() throws {
        let recorder = DestructionRecorder()
        var owner: MojoSessionOwner? = makeOwner(recorder: recorder)

        try owner?.shutdown()
        try owner?.shutdown()
        #expect(owner?.isShutdown == true)
        #expect(recorder.count == 1)

        owner = nil
        #expect(recorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func deinitDestroysAnActiveSessionExactlyOnce() {
        let recorder = DestructionRecorder()
        var owner: MojoSessionOwner? = makeOwner(recorder: recorder)

        #expect(owner?.isShutdown == false)
        owner = nil

        #expect(recorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func useAfterShutdownAndDomainMismatchAreTypedFailures() throws {
        let recorder = DestructionRecorder()
        let owner = makeOwner(recorder: recorder)

        #expect(
            throws: MojoSessionError.sessionDomainMismatch(
                expected: 18,
                actual: 17
            )
        ) {
            try owner.withOpaqueHandle(expectedSessionDomainID: 18) { _ in }
        }
        try owner.shutdown()
        #expect(throws: MojoSessionError.shutdown) {
            try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func shutdownWhileBorrowedFailsWithoutDestroyingTheHandle() throws {
        let recorder = DestructionRecorder()
        let owner = makeOwner(recorder: recorder)

        try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in
            #expect(throws: MojoSessionError.busy) {
                try owner.shutdown()
            }
            #expect(recorder.count == 0)
        }
        try owner.shutdown()
        #expect(recorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func reentrantBorrowFailsWithoutEndingTheOuterLease() throws {
        let recorder = DestructionRecorder()
        let owner = makeOwner(recorder: recorder)

        try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in
            #expect(throws: MojoSessionError.busy) {
                try owner.withOpaqueHandle(
                    expectedSessionDomainID: 17
                ) { _ in }
            }
            #expect(recorder.count == 0)
        }

        try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in }
        try owner.shutdown()
        #expect(recorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentUseAndShutdownFailWhileLeaseIsActive() async throws {
        let recorder = DestructionRecorder()
        let owner = makeOwner(recorder: recorder)
        let entered = Mutex(false)
        let release = Mutex(false)
        let borrow = Task.detached {
            try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in
                entered.withLock { $0 = true }
                while !release.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }

        while !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(throws: MojoSessionError.busy) {
            try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in }
        }
        #expect(throws: MojoSessionError.busy) {
            try owner.shutdown()
        }
        #expect(recorder.count == 0)

        release.withLock { $0 = true }
        try await borrow.value
        try owner.shutdown()
        #expect(recorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func activeResourceBlocksParentShutdownUntilExactDestruction() throws {
        let sessionRecorder = DestructionRecorder()
        let resourceRecorder = ResourceDestructionRecorder()
        let owner = makeOwner(recorder: sessionRecorder)
        let resource = try makeResource(
            owner: owner,
            recorder: resourceRecorder
        )

        #expect(throws: MojoSessionError.activeResources(1)) {
            try owner.shutdown()
        }
        try resource.shutdown()
        try resource.shutdown()
        #expect(resource.isShutdown)
        #expect(resourceRecorder.count == 1)

        try owner.shutdown()
        #expect(sessionRecorder.count == 1)
        #expect(resourceRecorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func resourceUseAfterShutdownIsTypedFailure() throws {
        let sessionRecorder = DestructionRecorder()
        let resourceRecorder = ResourceDestructionRecorder()
        let owner = makeOwner(recorder: sessionRecorder)
        let resource = try makeResource(
            owner: owner,
            recorder: resourceRecorder
        )

        try resource.withOpaqueHandles { session, resource in
            #expect(session != resource)
        }
        try resource.shutdown()
        #expect(throws: MojoSessionError.resourceShutdown) {
            try resource.withOpaqueHandles { _, _ in }
        }
        try owner.shutdown()
        try resource.shutdown()
        #expect(throws: MojoSessionError.resourceShutdown) {
            try resource.withOpaqueHandles { _, _ in }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func resourceDeinitDuringSessionBorrowDefersDestructionSafely() throws {
        let sessionRecorder = DestructionRecorder()
        let resourceRecorder = ResourceDestructionRecorder()
        let owner = makeOwner(recorder: sessionRecorder)
        var resource: MojoSessionResourceOwner? = try makeResource(
            owner: owner,
            recorder: resourceRecorder
        )

        try owner.withOpaqueHandle(expectedSessionDomainID: 17) { _ in
            resource = nil
            #expect(resourceRecorder.count == 0)
            #expect(throws: MojoSessionError.busy) {
                try owner.shutdown()
            }
        }

        #expect(resource == nil)
        #expect(resourceRecorder.count == 1)
        try owner.shutdown()
        #expect(sessionRecorder.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentResourceUseRejectsResourceAndParentShutdown() async throws {
        let sessionRecorder = DestructionRecorder()
        let resourceRecorder = ResourceDestructionRecorder()
        let owner = makeOwner(recorder: sessionRecorder)
        let resource = try makeResource(
            owner: owner,
            recorder: resourceRecorder
        )
        let entered = Mutex(false)
        let release = Mutex(false)
        let use = Task.detached {
            try resource.withOpaqueHandles { _, _ in
                entered.withLock { $0 = true }
                while !release.withLock({ $0 }) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }
        }

        while !entered.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(throws: MojoSessionError.busy) {
            try resource.shutdown()
        }
        #expect(throws: MojoSessionError.busy) {
            try owner.shutdown()
        }
        #expect(resourceRecorder.count == 0)

        release.withLock { $0 = true }
        try await use.value
        try resource.shutdown()
        try owner.shutdown()
        #expect(resourceRecorder.count == 1)
        #expect(sessionRecorder.count == 1)
    }

    private func makeOwner(recorder: DestructionRecorder) -> MojoSessionOwner {
        let handle = UnsafeMutableRawPointer.allocate(
            byteCount: 1,
            alignment: 1
        )
        return MojoSessionOwner(
            handle: handle,
            sessionDomainID: 17,
            capabilities: MojoSessionCapabilities(
                device: .cpu,
                ordinal: 0,
                availableCapabilities: [
                    .synchronousInvocation,
                    .hostAccessibleMemory,
                    .float32,
                ]
            ),
            destroy: { handle in
                recorder.destroy(handle)
            }
        )
    }

    private func makeResource(
        owner: MojoSessionOwner,
        recorder: ResourceDestructionRecorder
    ) throws -> MojoSessionResourceOwner {
        try owner.createResource(
            expectedSessionDomainID: 17,
            create: { _ in
                UnsafeMutableRawPointer.allocate(
                    byteCount: 1,
                    alignment: 1
                )
            },
            destroy: { _, resource in
                recorder.destroy(resource)
            }
        )
    }

    private final class DestructionRecorder: Sendable {
        private let storage = Mutex(0)

        var count: Int {
            storage.withLock { $0 }
        }

        func destroy(_ handle: UnsafeMutableRawPointer) {
            storage.withLock { $0 += 1 }
            handle.deallocate()
        }
    }

    private final class ResourceDestructionRecorder: Sendable {
        private let storage = Mutex(0)

        var count: Int {
            storage.withLock { $0 }
        }

        func destroy(_ resource: UnsafeMutableRawPointer) {
            storage.withLock { $0 += 1 }
            resource.deallocate()
        }
    }
}
