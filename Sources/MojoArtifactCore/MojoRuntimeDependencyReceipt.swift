import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeDependencyReceipt: Codable, Equatable, Sendable {
    package struct Library: Codable, Equatable, Sendable {
        package let fileName: String
        package let digest: String
        package let architecture: String
        package let installName: String
        package let dynamicDependencies: [String]
        package let providedSymbols: [String]

        package init(
            fileName: String,
            digest: String,
            architecture: String,
            installName: String,
            dynamicDependencies: [String],
            providedSymbols: [String]
        ) {
            self.fileName = fileName
            self.digest = digest
            self.architecture = architecture
            self.installName = installName
            self.dynamicDependencies = dynamicDependencies.sorted()
            self.providedSymbols = providedSymbols.sorted()
        }
    }

    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let linkagePolicyVersion: Int
    package let target: MojoTargetConfiguration
    package let objectDigest: String
    package let requiredSymbols: [String]
    package let systemDependencies: [String]
    package let libraries: [Library]

    package init(
        target: MojoTargetConfiguration,
        objectDigest: String,
        requiredSymbols: [String],
        systemDependencies: [String],
        libraries: [Library]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.linkagePolicyVersion = MojoObjectLinkageInspector.policyVersion
        self.target = target
        self.objectDigest = objectDigest
        self.requiredSymbols = requiredSymbols.sorted()
        self.systemDependencies = systemDependencies.sorted()
        self.libraries = libraries.sorted { $0.fileName < $1.fileName }
    }

    package var digest: String {
        var components = [
            "schema=\(schemaVersion)",
            "policy=\(linkagePolicyVersion)",
            "target=\(target.identity)",
            "object=\(objectDigest)",
        ]
        components.append(
            contentsOf: requiredSymbols.map { "symbol=\($0)" }
        )
        components.append(
            contentsOf: systemDependencies.map { "system=\($0)" }
        )
        for library in libraries {
            components.append(contentsOf: [
                "library=\(library.fileName)",
                "digest=\(library.digest)",
                "architecture=\(library.architecture)",
                "install-name=\(library.installName)",
            ])
            components.append(
                contentsOf: library.dynamicDependencies.map {
                    "dependency=\($0)"
                }
            )
            components.append(
                contentsOf: library.providedSymbols.map {
                    "provided=\($0)"
                }
            )
        }
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
        let receipt: Self
        do {
            receipt = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw MojoArtifactError.invalidRuntimeReceipt(
                String(describing: error)
            )
        }
        guard receipt.schemaVersion == currentSchemaVersion else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "unsupported schema version \(receipt.schemaVersion)"
            )
        }
        guard receipt.linkagePolicyVersion
                == MojoObjectLinkageInspector.policyVersion else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "unsupported linkage policy version \(receipt.linkagePolicyVersion)"
            )
        }
        return receipt
    }
}
