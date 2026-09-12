public final class MojoSessionResourceOwner: MojoSessionResource, Sendable {
    let session: MojoSessionOwner
    let resourceID: UInt64
    let factoryBindingID: UInt64
    private let sessionDomainID: UInt64

    init(
        session: MojoSessionOwner,
        resourceID: UInt64,
        sessionDomainID: UInt64,
        factoryBindingID: UInt64
    ) {
        self.session = session
        self.resourceID = resourceID
        self.sessionDomainID = sessionDomainID
        self.factoryBindingID = factoryBindingID
    }

    public var isShutdown: Bool {
        session.isResourceShutdown(resourceID: resourceID)
    }

    public func shutdown() throws {
        try session.shutdownResource(
            resourceID: resourceID,
            expectedSessionDomainID: sessionDomainID
        )
    }

    @_spi(SwiftMojoGenerated)
    public func withOpaqueHandles<Result>(
        _ operation: (
            UnsafeMutableRawPointer,
            UnsafeMutableRawPointer
        ) throws -> Result
    ) throws -> Result {
        try session.withResourceHandles(
            resourceID: resourceID,
            expectedSessionDomainID: sessionDomainID,
            operation
        )
    }

    deinit {
        session.abandonResource(resourceID: resourceID)
    }
}
