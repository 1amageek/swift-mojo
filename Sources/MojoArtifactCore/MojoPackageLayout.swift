import Foundation

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
        "Generated/\(targetName)/\(identity.artifactName)"
    }

    package func validatePackageTarget() throws {
        let fileManager = FileManager.default
        let manifestURL = packageRootURL.appendingPathComponent("Package.swift")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MojoArtifactError.invalidArguments(
                "No Package.swift was found at '\(packageRootURL.path)'"
            )
        }
        guard fileManager.fileExists(atPath: sourceRootURL.path) else {
            throw MojoArtifactError.invalidArguments(
                "SwiftPM source directory is missing at '\(sourceRootURL.path)'"
            )
        }
    }

    package func sourceURLs() throws -> [URL] {
        try validatePackageTarget()
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MojoArtifactError.invalidArguments(
                "SwiftPM source directory is unreadable at '\(sourceRootURL.path)'"
            )
        }
        var sources: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                sources.append(url)
            }
        }
        guard !sources.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "No Swift sources were found for target '\(targetName)'"
            )
        }
        return sources.sorted { $0.path < $1.path }
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

    package var sourceRootURL: URL {
        packageRootURL
            .appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(targetName, isDirectory: true)
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
