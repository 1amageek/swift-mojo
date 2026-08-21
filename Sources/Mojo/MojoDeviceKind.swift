public enum MojoDeviceKind: UInt32, CaseIterable, Codable, Sendable {
    case cpu = 0
    case metal = 1
    case cuda = 2
    case hip = 3
}
