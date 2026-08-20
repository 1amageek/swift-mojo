import MojoCompilerCore

package struct MojoXCFrameworkSliceIdentity: Hashable, Sendable {
    package let architecture: String
    package let platform: String
    package let variant: String?

    package init(target: MojoTargetConfiguration) throws {
        let normalized = target.triple.lowercased()
        if normalized.hasPrefix("arm64-")
            || normalized.hasPrefix("aarch64-") {
            architecture = "arm64"
        } else if normalized.hasPrefix("x86_64-") {
            architecture = "x86_64"
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }

        if normalized.contains("-apple-macos") {
            platform = "macos"
            variant = nil
        } else if normalized.contains("-apple-ios") {
            platform = "ios"
            variant = normalized.contains("simulator") ? "simulator" : nil
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    package var description: String {
        [platform, variant, architecture]
            .compactMap { $0 }
            .joined(separator: "/")
    }

    package var libraryGroupIdentity: String {
        [platform, variant ?? "none"].joined(separator: "/")
    }
}
