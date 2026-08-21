import Synchronization

public final class MojoSessionOwner: MojoSession, Sendable {
    // The foreign runtime handle has no Swift-native Sendable conformance.
    // Its pointee is accessed only through one synchronous lease at a time,
    // the wrapper never owns deallocation independently, and the Mutex is the
    // sole mutation entry point for the exactly-once ownership state.
    private struct OpaqueHandle: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
    }

    private struct State: Sendable {
        var handle: OpaqueHandle?
        var activeBorrowCount: Int
        var nextResourceID: UInt64
        var resources: [UInt64: ResourceRecord]
    }

    private struct ResourceRecord: Sendable {
        let handle: OpaqueHandle
        let destroy: @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) -> Void
        var isAbandoned: Bool
    }

    public let capabilities: MojoSessionCapabilities

    private let sessionDomainID: UInt64
    private let state: Mutex<State>
    private let destroy: @Sendable (UnsafeMutableRawPointer) -> Void

    @_spi(SwiftMojoGenerated)
    public init(
        handle: UnsafeMutableRawPointer,
        sessionDomainID: UInt64,
        capabilities: MojoSessionCapabilities,
        destroy: @escaping @Sendable (UnsafeMutableRawPointer) -> Void
    ) {
        self.sessionDomainID = sessionDomainID
        self.capabilities = capabilities
        self.destroy = destroy
        self.state = Mutex(
            State(
                handle: OpaqueHandle(pointer: handle),
                activeBorrowCount: 0,
                nextResourceID: 0,
                resources: [:]
            )
        )
    }

    public var isShutdown: Bool {
        state.withLock { state in
            state.handle == nil
        }
    }

    public func shutdown() throws {
        let handle = try state.withLock { state -> OpaqueHandle? in
            guard let handle = state.handle else {
                return nil
            }
            guard state.activeBorrowCount == 0 else {
                throw MojoSessionError.busy
            }
            guard state.resources.isEmpty else {
                throw MojoSessionError.activeResources(
                    state.resources.count
                )
            }
            state.handle = nil
            return handle
        }
        if let handle {
            destroy(handle.pointer)
        }
    }

    @_spi(SwiftMojoGenerated)
    public func withOpaqueHandle<Result>(
        expectedSessionDomainID: UInt64,
        _ operation: (UnsafeMutableRawPointer) throws -> Result
    ) throws -> Result {
        let handle = try beginBorrow(
            expectedSessionDomainID: expectedSessionDomainID
        )
        defer {
            finishBorrow(sessionHandle: handle)
        }
        return try operation(handle.pointer)
    }

    @_spi(SwiftMojoGenerated)
    public func createResource(
        expectedSessionDomainID: UInt64,
        create: (UnsafeMutableRawPointer) throws -> UnsafeMutableRawPointer,
        destroy: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) -> Void
    ) throws -> MojoSessionResourceOwner {
        let sessionHandle = try beginBorrow(
            expectedSessionDomainID: expectedSessionDomainID
        )
        defer {
            finishBorrow(sessionHandle: sessionHandle)
        }
        let resourceHandle = try create(sessionHandle.pointer)
        let resourceID: UInt64
        do {
            resourceID = try state.withLock { state in
                guard state.nextResourceID != UInt64.max else {
                    throw MojoSessionError.resourceIdentifierExhausted
                }
                let identifier = state.nextResourceID
                state.nextResourceID += 1
                state.resources[identifier] = ResourceRecord(
                    handle: OpaqueHandle(pointer: resourceHandle),
                    destroy: destroy,
                    isAbandoned: false
                )
                return identifier
            }
        } catch {
            destroy(sessionHandle.pointer, resourceHandle)
            throw error
        }
        return MojoSessionResourceOwner(
            session: self,
            resourceID: resourceID,
            sessionDomainID: expectedSessionDomainID
        )
    }

    @_spi(SwiftMojoGenerated)
    public func withResourceHandles<Result>(
        resourceID: UInt64,
        expectedSessionDomainID: UInt64,
        _ operation: (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) throws -> Result
    ) throws -> Result {
        let (sessionHandle, resourceHandle) = try beginResourceBorrow(
            resourceID: resourceID,
            expectedSessionDomainID: expectedSessionDomainID
        )
        defer {
            finishBorrow(sessionHandle: sessionHandle)
        }
        return try operation(sessionHandle.pointer, resourceHandle.pointer)
    }

    @_spi(SwiftMojoGenerated)
    public func shutdownResource(
        resourceID: UInt64,
        expectedSessionDomainID: UInt64
    ) throws {
        guard sessionDomainID == expectedSessionDomainID else {
            throw MojoSessionError.sessionDomainMismatch(
                expected: expectedSessionDomainID,
                actual: sessionDomainID
            )
        }
        let destruction = try state.withLock { state -> (
            OpaqueHandle,
            ResourceRecord
        )? in
            guard state.resources[resourceID] != nil else {
                return nil
            }
            guard let sessionHandle = state.handle else {
                preconditionFailure(
                    "An active resource must retain an active session"
                )
            }
            guard state.activeBorrowCount == 0 else {
                throw MojoSessionError.busy
            }
            guard let resource = state.resources.removeValue(
                forKey: resourceID
            ) else {
                preconditionFailure(
                    "The resource must remain registered while the state lock is held"
                )
            }
            state.activeBorrowCount = 1
            return (sessionHandle, resource)
        }
        guard let (sessionHandle, resource) = destruction else {
            return
        }
        resource.destroy(sessionHandle.pointer, resource.handle.pointer)
        finishBorrow(sessionHandle: sessionHandle)
    }

    @_spi(SwiftMojoGenerated)
    public func isResourceShutdown(resourceID: UInt64) -> Bool {
        state.withLock { state in
            state.resources[resourceID] == nil
        }
    }

    @_spi(SwiftMojoGenerated)
    public func abandonResource(resourceID: UInt64) {
        let destruction = state.withLock { state -> (
            OpaqueHandle,
            ResourceRecord
        )? in
            guard var resource = state.resources[resourceID] else {
                return nil
            }
            resource.isAbandoned = true
            state.resources[resourceID] = resource
            guard state.activeBorrowCount == 0,
                  let sessionHandle = state.handle,
                  let removed = state.resources.removeValue(
                    forKey: resourceID
                  ) else {
                return nil
            }
            state.activeBorrowCount = 1
            return (sessionHandle, removed)
        }
        if let (sessionHandle, resource) = destruction {
            resource.destroy(sessionHandle.pointer, resource.handle.pointer)
            finishBorrow(sessionHandle: sessionHandle)
        }
    }

    private func beginBorrow(
        expectedSessionDomainID: UInt64
    ) throws -> OpaqueHandle {
        guard sessionDomainID == expectedSessionDomainID else {
            throw MojoSessionError.sessionDomainMismatch(
                expected: expectedSessionDomainID,
                actual: sessionDomainID
            )
        }
        return try state.withLock { state in
            guard let handle = state.handle else {
                throw MojoSessionError.shutdown
            }
            guard state.activeBorrowCount == 0 else {
                throw MojoSessionError.busy
            }
            state.activeBorrowCount = 1
            return handle
        }
    }

    private func beginResourceBorrow(
        resourceID: UInt64,
        expectedSessionDomainID: UInt64
    ) throws -> (OpaqueHandle, OpaqueHandle) {
        guard sessionDomainID == expectedSessionDomainID else {
            throw MojoSessionError.sessionDomainMismatch(
                expected: expectedSessionDomainID,
                actual: sessionDomainID
            )
        }
        return try state.withLock { state in
            guard let resource = state.resources[resourceID],
                  !resource.isAbandoned else {
                throw MojoSessionError.resourceShutdown
            }
            guard let sessionHandle = state.handle else {
                preconditionFailure(
                    "An active resource must retain an active session"
                )
            }
            guard state.activeBorrowCount == 0 else {
                throw MojoSessionError.busy
            }
            state.activeBorrowCount = 1
            return (sessionHandle, resource.handle)
        }
    }

    private func finishBorrow(sessionHandle: OpaqueHandle) {
        while true {
            let abandoned = state.withLock { state -> ResourceRecord? in
                precondition(state.activeBorrowCount == 1)
                if let identifier = state.resources
                    .filter({ $0.value.isAbandoned })
                    .map(\.key)
                    .min() {
                    return state.resources.removeValue(forKey: identifier)
                }
                state.activeBorrowCount = 0
                return nil
            }
            guard let abandoned else {
                return
            }
            abandoned.destroy(
                sessionHandle.pointer,
                abandoned.handle.pointer
            )
        }
    }

    deinit {
        let handle = state.withLock { state -> OpaqueHandle? in
            precondition(state.activeBorrowCount == 0)
            precondition(state.resources.isEmpty)
            defer { state.handle = nil }
            return state.handle
        }
        if let handle {
            destroy(handle.pointer)
        }
    }
}
