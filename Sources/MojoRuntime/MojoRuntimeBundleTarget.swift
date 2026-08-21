public struct MojoRuntimeBundleTarget: Codable, Equatable, Sendable {
    public let triple: String
    public let cpu: String
    public let accelerator: String?

    public init(triple: String, cpu: String, accelerator: String?) {
        self.triple = triple
        self.cpu = cpu
        self.accelerator = accelerator
    }

    public var identity: String {
        [triple, cpu, accelerator ?? "none"].joined(separator: "|")
    }
}
