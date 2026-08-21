public protocol MojoSession: AnyObject, Sendable {
    var capabilities: MojoSessionCapabilities { get }
    var isShutdown: Bool { get }

    func shutdown() throws
}
