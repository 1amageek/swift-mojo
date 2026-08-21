public struct MojoRuntimeBundleVerification: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let bundleDigest: String
    public let receiptDigest: String
    public let target: MojoRuntimeBundleTarget
    public let loaderSearchPath: String
    public let programInterpreter: String?
    public let executable: MojoRuntimeBundleFile
    public let libraries: [MojoRuntimeBundleFile]
    public let systemDependencies: [String]

    public init(
        schemaVersion: Int,
        bundleDigest: String,
        receiptDigest: String,
        target: MojoRuntimeBundleTarget,
        loaderSearchPath: String,
        programInterpreter: String?,
        executable: MojoRuntimeBundleFile,
        libraries: [MojoRuntimeBundleFile],
        systemDependencies: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleDigest = bundleDigest
        self.receiptDigest = receiptDigest
        self.target = target
        self.loaderSearchPath = loaderSearchPath
        self.programInterpreter = programInterpreter
        self.executable = executable
        self.libraries = libraries
        self.systemDependencies = systemDependencies
    }
}
