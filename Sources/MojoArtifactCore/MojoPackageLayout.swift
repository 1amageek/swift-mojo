import Foundation
import MojoCompilerCore

package struct MojoPackageLayout: Equatable, Sendable {
    package let packageRootURL: URL
    package let targetName: String
    package let identity: MojoArtifactIdentity

    package init(packageRootURL: URL, targetName: String) throws {
        guard Self.isIdentifier(targetName) else {
            throw MojoArtifactError.invalidArguments(
                "Target name '\(targetName)' is not a portable SwiftPM target identifier"
            )
        }
        self.packageRootURL = packageRootURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.targetName = targetName
        self.identity = try MojoArtifactIdentity(targetName: targetName)
    }

    package var outputDirectoryURL: URL {
        packageRootURL
            .appendingPathComponent("Generated", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
    }

    package var binaryTargetRelativePath: String {
        binaryTargetRelativePath(adapter: .appleXCFramework)
    }

    package func binaryTargetRelativePath(
        adapter: MojoNativeArtifactAdapter
    ) -> String {
        "Generated/\(targetName)/\(adapter.artifactName(identity: identity))"
    }

    package func binaryIntegrations(
        targets: [MojoTargetConfiguration]
    ) throws -> [MojoPackageBinaryIntegration] {
        let groups = try Dictionary(grouping: targets) {
            try MojoNativeArtifactAdapter(target: $0)
        }
        return groups.keys.sorted { $0.rawValue < $1.rawValue }.map { adapter in
            MojoPackageBinaryIntegration(
                adapter: adapter,
                identity: identity,
                targetName: targetName,
                targets: groups[adapter, default: []]
            )
        }
    }

    package func validatePackageTarget() throws {
        let fileManager = FileManager.default
        let manifestURL = packageRootURL.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MojoArtifactError.invalidArguments(
                "No Package.swift was found at '\(packageRootURL.path)'"
            )
        }
        try MojoRegularFile.validate(at: manifestURL)
    }

    package func externalPackages(names: [String]) throws -> [MojoExternalPackage] {
        try names.sorted().map { name in
            try MojoExternalPackage(
                name: name,
                rootURL: packageRootURL
                    .appendingPathComponent("Mojo", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
            )
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { codeUnit in
            codeUnit == 45
                || codeUnit == 95
                || (codeUnit >= 48 && codeUnit <= 57)
                || (codeUnit >= 65 && codeUnit <= 90)
                || (codeUnit >= 97 && codeUnit <= 122)
        }
    }
}
