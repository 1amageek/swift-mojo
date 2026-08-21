public struct MojoSessionCapabilities: Equatable, Sendable {
    public let device: MojoDeviceKind
    public let ordinal: UInt32
    public let availableCapabilities: MojoSessionCapability

    public init(
        device: MojoDeviceKind,
        ordinal: UInt32,
        availableCapabilities: MojoSessionCapability
    ) {
        self.device = device
        self.ordinal = ordinal
        self.availableCapabilities = availableCapabilities
    }

    public func satisfies(_ requirements: MojoSessionRequirements) -> Bool {
        device == requirements.device
            && ordinal == requirements.ordinal
            && availableCapabilities.isSuperset(
                of: requirements.requiredCapabilities
            )
    }
}
