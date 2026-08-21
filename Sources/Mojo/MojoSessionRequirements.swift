public struct MojoSessionRequirements: Equatable, Sendable {
    public static let currentSchemaVersion: UInt32 = 1

    public let device: MojoDeviceKind
    public let ordinal: UInt32
    public let requiredCapabilities: MojoSessionCapability

    public init(
        device: MojoDeviceKind,
        ordinal: UInt32 = 0,
        requiredCapabilities: MojoSessionCapability = []
    ) {
        self.device = device
        self.ordinal = ordinal
        self.requiredCapabilities = requiredCapabilities
    }
}
