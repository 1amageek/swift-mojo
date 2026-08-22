package struct MojoRuntimeBinaryInspection: Equatable, Sendable {
    package let architecture: String
    package let installName: String
    package let dynamicDependencies: [String]
    package let runtimeSearchPaths: [String]
    package let exportedSymbols: Set<String>

    package init(
        architecture: String,
        installName: String,
        dynamicDependencies: [String],
        runtimeSearchPaths: [String] = [],
        exportedSymbols: Set<String>
    ) {
        self.architecture = architecture
        self.installName = installName
        self.dynamicDependencies = dynamicDependencies.sorted()
        self.runtimeSearchPaths = runtimeSearchPaths.sorted()
        self.exportedSymbols = exportedSymbols
    }
}
