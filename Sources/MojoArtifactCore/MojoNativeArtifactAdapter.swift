import MojoCompilerCore

package enum MojoNativeArtifactAdapter: String, Codable, Sendable {
    case appleXCFramework
    case linuxStaticLibraryBundle

    package init(target: MojoTargetConfiguration) throws {
        let normalized = target.triple.lowercased()
        let supportedArchitecture = normalized.hasPrefix("arm64-")
            || normalized.hasPrefix("aarch64-")
            || normalized.hasPrefix("x86_64-")
        guard supportedArchitecture else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        if normalized.contains("-apple-macos")
            || normalized.contains("-apple-ios") {
            self = .appleXCFramework
        } else if normalized.contains("-linux-") {
            self = .linuxStaticLibraryBundle
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    package func artifactName(identity: MojoArtifactIdentity) -> String {
        switch self {
        case .appleXCFramework:
            identity.artifactName
        case .linuxStaticLibraryBundle:
            identity.linuxArtifactName
        }
    }

    package func binaryTargetName(identity: MojoArtifactIdentity) -> String {
        switch self {
        case .appleXCFramework:
            identity.moduleName
        case .linuxStaticLibraryBundle:
            identity.linuxBinaryTargetName
        }
    }

    package static func validate(
        targets: [MojoTargetConfiguration],
        error: (String) -> MojoArtifactError
    ) throws {
        let grouped = try Dictionary(grouping: targets) {
            try MojoNativeArtifactAdapter(target: $0)
        }
        if let appleTargets = grouped[.appleXCFramework] {
            let selectors = try appleTargets.map {
                try MojoXCFrameworkSliceIdentity(target: $0)
            }
            guard Set(selectors).count == selectors.count else {
                throw error(
                    "Apple slices contain platform/architecture variants that XCFramework cannot distinguish"
                )
            }
        }
        if let linuxTargets = grouped[.linuxStaticLibraryBundle] {
            let triples = linuxTargets.map { $0.triple.lowercased() }
            guard Set(triples).count == triples.count else {
                throw error(
                    "Linux slices contain target triples that SwiftPM artifact selection cannot distinguish"
                )
            }
        }
    }
}
