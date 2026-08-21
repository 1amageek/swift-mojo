import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeBundleManifest: Codable, Equatable, Sendable {
    package struct File: Codable, Equatable, Sendable {
        package let relativePath: String
        package let digest: String

        package init(relativePath: String, digest: String) {
            self.relativePath = relativePath
            self.digest = digest
        }
    }

    package static let currentSchemaVersion = 1
    package static let fileName = "RuntimeBundle.json"
    package static let receiptFileName = "RuntimeReceipt.json"

    package let schemaVersion: Int
    package let receiptDigest: String
    package let target: MojoTargetConfiguration
    package let loaderSearchPath: String
    package let programInterpreter: String?
    package let executable: File
    package let libraries: [File]
    package let systemDependencies: [String]

    package init(
        receiptDigest: String,
        target: MojoTargetConfiguration,
        loaderSearchPath: String,
        programInterpreter: String?,
        executable: File,
        libraries: [File],
        systemDependencies: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.receiptDigest = receiptDigest
        self.target = target
        self.loaderSearchPath = loaderSearchPath
        self.programInterpreter = programInterpreter
        self.executable = executable
        self.libraries = libraries.sorted {
            $0.relativePath < $1.relativePath
        }
        self.systemDependencies = systemDependencies.sorted()
    }

    package var digest: String {
        var components = [
            "schema=\(schemaVersion)",
            "receipt=\(receiptDigest)",
            "target=\(target.identity)",
            "loader=\(loaderSearchPath)",
            "interpreter=\(programInterpreter ?? "none")",
            "executable=\(executable.relativePath)",
            "executable-digest=\(executable.digest)",
        ]
        for library in libraries {
            components.append("library=\(library.relativePath)")
            components.append("library-digest=\(library.digest)")
        }
        components.append(
            contentsOf: systemDependencies.map { "system=\($0)" }
        )
        let canonical = components.map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "|")
        return MojoCanonicalDigest.hex(canonical)
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> Self {
        let manifest: Self
        do {
            manifest = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw MojoArtifactError.invalidRuntimeBundle(
                String(describing: error)
            )
        }
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "unsupported schema version \(manifest.schemaVersion)"
            )
        }
        return manifest
    }
}
