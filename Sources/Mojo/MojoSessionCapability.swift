public struct MojoSessionCapability: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let synchronousInvocation = Self(rawValue: 1 << 0)
    public static let hostAccessibleMemory = Self(rawValue: 1 << 1)
    public static let deviceMemory = Self(rawValue: 1 << 2)
    public static let hostPinnedMemory = Self(rawValue: 1 << 3)
    public static let float32 = Self(rawValue: 1 << 4)
    public static let float64 = Self(rawValue: 1 << 5)

    public static let allKnown: Self = [
        .synchronousInvocation,
        .hostAccessibleMemory,
        .deviceMemory,
        .hostPinnedMemory,
        .float32,
        .float64,
    ]
}
