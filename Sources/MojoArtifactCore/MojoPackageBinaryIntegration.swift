import MojoCompilerCore

package struct MojoPackageBinaryIntegration: Equatable, Sendable {
    package let adapter: MojoNativeArtifactAdapter
    package let binaryTargetName: String
    package let binaryTargetPath: String
    package let platforms: Set<String>

    package init(
        adapter: MojoNativeArtifactAdapter,
        binaryTargetName: String,
        binaryTargetPath: String,
        platforms: Set<String>
    ) {
        self.adapter = adapter
        self.binaryTargetName = binaryTargetName
        self.binaryTargetPath = binaryTargetPath
        self.platforms = platforms
    }

    package init(
        adapter: MojoNativeArtifactAdapter,
        identity: MojoArtifactIdentity,
        targetName: String,
        targets: [MojoTargetConfiguration]
    ) {
        self.adapter = adapter
        self.binaryTargetName = adapter.binaryTargetName(identity: identity)
        self.binaryTargetPath = "Generated/\(targetName)/\(adapter.artifactName(identity: identity))"
        self.platforms = Set(targets.compactMap(Self.platformName))
    }

    private static func platformName(
        target: MojoTargetConfiguration
    ) -> String? {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-macos") {
            return "macOS"
        }
        if triple.contains("-apple-ios") {
            return "iOS"
        }
        if triple.contains("-linux-") {
            return "linux"
        }
        return nil
    }
}
