import Foundation
import MojoBindingCore

package struct MojoExternalPackage: Codable, Equatable, Sendable {
    package let name: String
    package let rootURL: URL
    package let sourceURLs: [URL]
    package let digest: String

    package init(name: String, rootURL: URL) throws {
        let fileManager = FileManager.default
        let standardizedRoot = rootURL.standardizedFileURL
        guard MojoPortableIdentifier.isValid(name),
              standardizedRoot.lastPathComponent == name else {
            throw MojoArtifactError.invalidExternalPackage(
                "Package name '\(name)' must be a portable identifier matching its directory"
            )
        }
        let initializer = standardizedRoot.appendingPathComponent("__init__.mojo")
        guard fileManager.fileExists(atPath: initializer.path) else {
            throw MojoArtifactError.invalidExternalPackage(
                "Mojo package '\(name)' requires __init__.mojo at '\(standardizedRoot.path)'"
            )
        }
        guard let enumerator = fileManager.enumerator(
            at: standardizedRoot,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw MojoArtifactError.invalidExternalPackage(
                "Mojo package '\(name)' is unreadable at '\(standardizedRoot.path)'"
            )
        }
        var sources: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw MojoArtifactError.invalidExternalPackage(
                    "Mojo package '\(name)' cannot contain symbolic links: '\(url.path)'"
                )
            }
            if values.isRegularFile == true {
                sources.append(url.standardizedFileURL)
            }
        }
        sources.sort { $0.path < $1.path }
        guard sources.contains(where: { $0.pathExtension == "mojo" }) else {
            throw MojoArtifactError.invalidExternalPackage(
                "Mojo package '\(name)' does not contain source files"
            )
        }

        let records = try sources.map { source -> String in
            let relative = String(
                source.path.dropFirst(standardizedRoot.path.count + 1)
            )
            return "\(relative)|\(try MojoCanonicalDigest.file(at: source))"
        }
        self.name = name
        self.rootURL = standardizedRoot
        self.sourceURLs = sources
        self.digest = MojoCanonicalDigest.hex(records.joined(separator: "\n"))
    }

    package var manifestRecord: MojoArtifactManifest.ExternalPackage {
        MojoArtifactManifest.ExternalPackage(name: name, digest: digest)
    }

}
