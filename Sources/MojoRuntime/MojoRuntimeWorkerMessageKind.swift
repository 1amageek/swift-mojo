public struct MojoRuntimeWorkerMessageKind: Equatable, Sendable {
    public let rawValue: UInt16
    public let name: String

    package init(rawValue: UInt16, name: String) {
        self.rawValue = rawValue
        self.name = name
    }
}
