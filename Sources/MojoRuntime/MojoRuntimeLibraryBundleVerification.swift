public struct MojoRuntimeLibraryBundleVerification:
    Codable, Equatable, Sendable
{
    public let schemaVersion: Int
    public let bundleDigest: String
    public let receiptDigest: String
    public let target: MojoRuntimeBundleTarget
    public let moduleName: String
    public let loaderSearchPath: String
    public let library: MojoRuntimeBundleFile
    public let runtimeLibraries: [MojoRuntimeBundleFile]
    public let interfaceHeader: MojoRuntimeBundleFile
    public let moduleMap: MojoRuntimeBundleFile
    public let exportedSymbols: [String]
    public let systemDependencies: [String]

    public init(
        schemaVersion: Int,
        bundleDigest: String,
        receiptDigest: String,
        target: MojoRuntimeBundleTarget,
        moduleName: String,
        loaderSearchPath: String,
        library: MojoRuntimeBundleFile,
        runtimeLibraries: [MojoRuntimeBundleFile],
        interfaceHeader: MojoRuntimeBundleFile,
        moduleMap: MojoRuntimeBundleFile,
        exportedSymbols: [String],
        systemDependencies: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.bundleDigest = bundleDigest
        self.receiptDigest = receiptDigest
        self.target = target
        self.moduleName = moduleName
        self.loaderSearchPath = loaderSearchPath
        self.library = library
        self.runtimeLibraries = runtimeLibraries
        self.interfaceHeader = interfaceHeader
        self.moduleMap = moduleMap
        self.exportedSymbols = exportedSymbols
        self.systemDependencies = systemDependencies
    }
}
