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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case relativePath
            case digest
        }

        package init(from decoder: Decoder) throws {
            try requireRuntimeBundleKeys(
                required: Set(CodingKeys.allCases.map(\.stringValue)),
                allowed: Set(CodingKeys.allCases.map(\.stringValue)),
                decoder: decoder
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                relativePath: try container.decode(
                    String.self,
                    forKey: .relativePath
                ),
                digest: try container.decode(String.self, forKey: .digest)
            )
            guard isRuntimeBundleDigest(digest) else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "file digest is not a lowercase SHA-256 value"
                )
            }
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case receiptDigest
        case target
        case loaderSearchPath
        case programInterpreter
        case executable
        case libraries
        case systemDependencies
    }

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

    package init(from decoder: Decoder) throws {
        let required = Set(
            CodingKeys.allCases.filter { $0 != .programInterpreter }
                .map(\.stringValue)
        )
        try requireRuntimeBundleKeys(
            required: required,
            allowed: Set(CodingKeys.allCases.map(\.stringValue)),
            decoder: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == Self.currentSchemaVersion else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "unsupported schema version \(schemaVersion)"
            )
        }
        let receiptDigest = try container.decode(
            String.self,
            forKey: .receiptDigest
        )
        guard isRuntimeBundleDigest(receiptDigest) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "receipt digest is not a lowercase SHA-256 value"
            )
        }
        let target = try container.decode(
            RuntimeBundleTargetRecord.self,
            forKey: .target
        ).target
        let libraries = try container.decode([File].self, forKey: .libraries)
        guard libraries == libraries.sorted(by: {
            $0.relativePath < $1.relativePath
        }), Set(libraries.map(\.relativePath)).count == libraries.count else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime library files must use unique canonical path order"
            )
        }
        let systemDependencies = try container.decode(
            [String].self,
            forKey: .systemDependencies
        )
        guard systemDependencies == systemDependencies.sorted(),
              Set(systemDependencies).count == systemDependencies.count else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "system dependencies must use unique canonical order"
            )
        }
        self.init(
            receiptDigest: receiptDigest,
            target: target,
            loaderSearchPath: try container.decode(
                String.self,
                forKey: .loaderSearchPath
            ),
            programInterpreter: try container.decodeIfPresent(
                String.self,
                forKey: .programInterpreter
            ),
            executable: try container.decode(File.self, forKey: .executable),
            libraries: libraries,
            systemDependencies: systemDependencies
        )
    }
}

private struct RuntimeBundleDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private struct RuntimeBundleTargetRecord: Decodable {
    let target: MojoTargetConfiguration

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case triple
        case cpu
        case accelerator
    }

    init(from decoder: Decoder) throws {
        try requireRuntimeBundleKeys(
            required: [CodingKeys.triple.stringValue, CodingKeys.cpu.stringValue],
            allowed: Set(CodingKeys.allCases.map(\.stringValue)),
            decoder: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try MojoTargetConfiguration(
            triple: container.decode(String.self, forKey: .triple),
            cpu: container.decode(String.self, forKey: .cpu),
            accelerator: container.decodeIfPresent(
                String.self,
                forKey: .accelerator
            )
        )
    }
}

private func requireRuntimeBundleKeys(
    required: Set<String>,
    allowed: Set<String>,
    decoder: Decoder
) throws {
    let container = try decoder.container(
        keyedBy: RuntimeBundleDynamicCodingKey.self
    )
    let actual = Set(container.allKeys.map(\.stringValue))
    let missing = required.subtracting(actual)
    let unknown = actual.subtracting(allowed)
    guard missing.isEmpty, unknown.isEmpty else {
        throw MojoArtifactError.invalidRuntimeBundle(
            "closed record key mismatch; missing=\(missing.sorted()), unknown=\(unknown.sorted())"
        )
    }
}

private func isRuntimeBundleDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}
