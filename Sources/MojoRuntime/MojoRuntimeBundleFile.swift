public struct MojoRuntimeBundleFile: Codable, Equatable, Sendable {
    public let relativePath: String
    public let sha256Digest: String

    public init(relativePath: String, sha256Digest: String) {
        self.relativePath = relativePath
        self.sha256Digest = sha256Digest
    }
}
