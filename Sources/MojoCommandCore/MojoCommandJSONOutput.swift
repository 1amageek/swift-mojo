import MojoArtifactCore

package struct MojoCommandJSONOutput: Codable, Equatable, Sendable {
    package let success: Bool
    package let command: String
    package let message: String
    package let target: String?
    package let module: String?
    package let compilerVersion: String?
    package let inputGraphDigest: String?
    package let artifactDigest: String?
    package let bindingCount: Int?
    package let slices: [String]?
    package let externalPackages: [String]?
    package let checks: [MojoDoctorReport.Check]?
    package let generatedMojo: String?
    package let runtimeLibraries: [String]?

    package init(
        success: Bool,
        command: String,
        message: String,
        target: String? = nil,
        module: String? = nil,
        compilerVersion: String? = nil,
        inputGraphDigest: String? = nil,
        artifactDigest: String? = nil,
        bindingCount: Int? = nil,
        slices: [String]? = nil,
        externalPackages: [String]? = nil,
        checks: [MojoDoctorReport.Check]? = nil,
        generatedMojo: String? = nil,
        runtimeLibraries: [String]? = nil
    ) {
        self.success = success
        self.command = command
        self.message = message
        self.target = target
        self.module = module
        self.compilerVersion = compilerVersion
        self.inputGraphDigest = inputGraphDigest
        self.artifactDigest = artifactDigest
        self.bindingCount = bindingCount
        self.slices = slices
        self.externalPackages = externalPackages
        self.checks = checks
        self.generatedMojo = generatedMojo
        self.runtimeLibraries = runtimeLibraries
    }
}
