public protocol MojoSessionResource: AnyObject, Sendable {
    var isShutdown: Bool { get }

    func shutdown() throws
}
