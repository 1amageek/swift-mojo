public final class MojoFloat32BufferOwner: MojoFloat32Buffer, Sendable {
    public let elementCount: UInt64
    public let byteCount: UInt64
    public let device: MojoDeviceKind
    public let memoryKind: MojoBufferMemoryKind

    private let resource: MojoSessionResourceOwner
    // The resource record retains both foreign owners for every call. The host
    // pointer is valid only inside the Swift unsafe-buffer closure, the exact
    // element count is validated before borrowing either foreign handle, and
    // the implementation must complete any queued transfer before returning.
    // Neither closure may retain a pointer or perform work asynchronously.
    private let copyFromHost: @Sendable (
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer,
        UnsafePointer<Float>,
        UInt64
    ) throws -> Void
    private let copyToHost: @Sendable (
        UnsafeMutableRawPointer,
        UnsafeMutableRawPointer,
        UnsafeMutablePointer<Float>,
        UInt64
    ) throws -> Void

    private init(
        resource: MojoSessionResourceOwner,
        elementCount: UInt64,
        byteCount: UInt64,
        device: MojoDeviceKind,
        memoryKind: MojoBufferMemoryKind,
        copyFromHost: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer,
            UnsafePointer<Float>,
            UInt64
        ) throws -> Void,
        copyToHost: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer,
            UnsafeMutablePointer<Float>,
            UInt64
        ) throws -> Void
    ) {
        self.resource = resource
        self.elementCount = elementCount
        self.byteCount = byteCount
        self.device = device
        self.memoryKind = memoryKind
        self.copyFromHost = copyFromHost
        self.copyToHost = copyToHost
    }

    public var isShutdown: Bool {
        resource.isShutdown
    }

    public func shutdown() throws {
        try resource.shutdown()
    }

    public func copy(from source: borrowing [Float]) throws {
        let actualElementCount = UInt64(source.count)
        guard actualElementCount == elementCount else {
            throw MojoBufferError.elementCountMismatch(
                expected: elementCount,
                actual: actualElementCount
            )
        }
        try source.withUnsafeBufferPointer { sourceBuffer in
            guard let sourceAddress = sourceBuffer.baseAddress else {
                preconditionFailure(
                    "A non-empty Swift buffer must expose a base address"
                )
            }
            try resource.withOpaqueHandles { sessionHandle, bufferHandle in
                try copyFromHost(
                    sessionHandle,
                    bufferHandle,
                    sourceAddress,
                    actualElementCount
                )
            }
        }
    }

    public func copy(into destination: inout [Float]) throws {
        let actualElementCount = UInt64(destination.count)
        guard actualElementCount == elementCount else {
            throw MojoBufferError.elementCountMismatch(
                expected: elementCount,
                actual: actualElementCount
            )
        }
        try destination.withUnsafeMutableBufferPointer { destinationBuffer in
            guard let destinationAddress = destinationBuffer.baseAddress else {
                preconditionFailure(
                    "A non-empty Swift buffer must expose a base address"
                )
            }
            try resource.withOpaqueHandles { sessionHandle, bufferHandle in
                try copyToHost(
                    sessionHandle,
                    bufferHandle,
                    destinationAddress,
                    actualElementCount
                )
            }
        }
    }

    @_spi(SwiftMojoGenerated)
    public static func create(
        session: MojoSessionOwner,
        expectedSessionDomainID: UInt64,
        elementCount: UInt64,
        memoryKind: MojoBufferMemoryKind,
        create: (UnsafeMutableRawPointer, UInt64) throws
            -> UnsafeMutableRawPointer,
        destroy: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) -> Void,
        copyFromHost: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer,
            UnsafePointer<Float>,
            UInt64
        ) throws -> Void,
        copyToHost: @escaping @Sendable (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer,
            UnsafeMutablePointer<Float>,
            UInt64
        ) throws -> Void
    ) throws -> MojoFloat32BufferOwner {
        guard elementCount > 0 else {
            throw MojoBufferError.zeroElementCountUnsupported
        }
        let requiredCapabilities: MojoSessionCapability = [
            .synchronousInvocation,
            .float32,
            memoryKind.requiredCapability,
        ]
        let availableCapabilities = session.capabilities.availableCapabilities
        guard availableCapabilities.isSuperset(of: requiredCapabilities) else {
            throw MojoBufferError.missingCapabilities(
                required: requiredCapabilities,
                available: availableCapabilities
            )
        }
        let (byteCount, overflow) = elementCount.multipliedReportingOverflow(
            by: UInt64(MemoryLayout<Float>.stride)
        )
        guard !overflow else {
            throw MojoBufferError.sizeOverflow(
                elementCount: elementCount,
                elementStride: UInt64(MemoryLayout<Float>.stride)
            )
        }
        let resource = try session.createResource(
            expectedSessionDomainID: expectedSessionDomainID,
            create: { sessionHandle in
                try create(sessionHandle, elementCount)
            },
            destroy: destroy
        )
        return MojoFloat32BufferOwner(
            resource: resource,
            elementCount: elementCount,
            byteCount: byteCount,
            device: session.capabilities.device,
            memoryKind: memoryKind,
            copyFromHost: copyFromHost,
            copyToHost: copyToHost
        )
    }

    @_spi(SwiftMojoGenerated)
    public func withOpaqueHandles<Result>(
        _ operation: (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) throws -> Result
    ) throws -> Result {
        try resource.withOpaqueHandles(operation)
    }
}
