package struct MojoRuntimeExecutableInspection: Equatable, Sendable {
    package let architecture: String
    package let dynamicDependencies: [String]
    package let runtimeSearchPaths: [String]
    package let programInterpreter: String?

    package init(
        architecture: String,
        dynamicDependencies: [String],
        runtimeSearchPaths: [String],
        programInterpreter: String?
    ) {
        self.architecture = architecture
        self.dynamicDependencies = dynamicDependencies.sorted()
        self.runtimeSearchPaths = runtimeSearchPaths.sorted()
        self.programInterpreter = programInterpreter
    }
}
