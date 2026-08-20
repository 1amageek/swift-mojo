package struct MojoProcessResult: Equatable, Sendable {
    package let status: Int32
    package let output: String

    package init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}
