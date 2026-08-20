package struct MojoCommandResult: Equatable, Sendable {
    package let exitCode: Int32
    package let standardOutput: String
    package let standardError: String

    package init(
        exitCode: Int32,
        standardOutput: String = "",
        standardError: String = ""
    ) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}
