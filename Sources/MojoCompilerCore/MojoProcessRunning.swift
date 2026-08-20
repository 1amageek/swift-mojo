package protocol MojoProcessRunning: Sendable {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult
}
