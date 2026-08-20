package struct MojoSourceReference: Codable, Equatable, Sendable {
    package let file: String
    package let line: Int
    package let column: Int

    package init(file: String, line: Int, column: Int) {
        self.file = file
        self.line = line
        self.column = column
    }
}
