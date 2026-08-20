package struct MojoRenderedSource: Equatable, Sendable {
    package let source: String
    package let sourceMap: MojoSourceMap

    package init(source: String, sourceMap: MojoSourceMap) {
        self.source = source
        self.sourceMap = sourceMap
    }
}
