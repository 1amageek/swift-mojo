public enum MojoBufferMemoryKind: UInt32, Codable, Sendable {
    case host = 0
    case device = 1
    case hostPinned = 2

    var requiredCapability: MojoSessionCapability {
        switch self {
        case .host:
            .hostAccessibleMemory
        case .device:
            .deviceMemory
        case .hostPinned:
            .hostPinnedMemory
        }
    }
}
