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

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case fileName
            case digest
            case architecture
            case installName
            case dynamicDependencies
            case providedSymbols
        }

        package init(from decoder: Decoder) throws {
            try requireRuntimeReceiptKeys(
                required: Set(CodingKeys.allCases.map(\.stringValue)),
                allowed: Set(CodingKeys.allCases.map(\.stringValue)),
                decoder: decoder
            )
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let dynamicDependencies = try container.decode(
                [String].self,
                forKey: .dynamicDependencies
            )
            let providedSymbols = try container.decode(
                [String].self,
                forKey: .providedSymbols
            )
            guard isCanonicalRuntimeReceiptList(dynamicDependencies),
                  isCanonicalRuntimeReceiptList(providedSymbols) else {
                throw MojoArtifactError.invalidRuntimeReceipt(
                    "runtime library dependencies and symbols must use unique canonical order"
                )
            }
            self.init(
                fileName: try container.decode(String.self, forKey: .fileName),
                digest: try container.decode(String.self, forKey: .digest),
                architecture: try container.decode(
                    String.self,
                    forKey: .architecture
                ),
                installName: try container.decode(
                    String.self,
                    forKey: .installName
                ),
                dynamicDependencies: dynamicDependencies,
                providedSymbols: providedSymbols
            )
            guard !fileName.isEmpty,
                  !architecture.isEmpty,
                  !installName.isEmpty,
                  isRuntimeReceiptDigest(digest) else {
                throw MojoArtifactError.invalidRuntimeReceipt(
                    "runtime library identity is invalid"
                )
            }
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

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case linkagePolicyVersion
        case target
        case objectDigest
        case requiredSymbols
        case systemDependencies
        case libraries
    }

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

    package init(from decoder: Decoder) throws {
        try requireRuntimeReceiptKeys(
            required: Set(CodingKeys.allCases.map(\.stringValue)),
            allowed: Set(CodingKeys.allCases.map(\.stringValue)),
            decoder: decoder
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        let policyVersion = try container.decode(
            Int.self,
            forKey: .linkagePolicyVersion
        )
        guard schemaVersion == Self.currentSchemaVersion,
              policyVersion == MojoObjectLinkageInspector.policyVersion else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "schema or linkage policy version is unsupported"
            )
        }
        let objectDigest = try container.decode(
            String.self,
            forKey: .objectDigest
        )
        guard isRuntimeReceiptDigest(objectDigest) else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "object digest is not a lowercase SHA-256 value"
            )
        }
        let requiredSymbols = try container.decode(
            [String].self,
            forKey: .requiredSymbols
        )
        let systemDependencies = try container.decode(
            [String].self,
            forKey: .systemDependencies
        )
        let libraries = try container.decode([Library].self, forKey: .libraries)
        guard isCanonicalRuntimeReceiptList(requiredSymbols),
              isCanonicalRuntimeReceiptList(systemDependencies),
              libraries == libraries.sorted(by: { $0.fileName < $1.fileName }),
              Set(libraries.map(\.fileName)).count == libraries.count else {
            throw MojoArtifactError.invalidRuntimeReceipt(
                "runtime receipt records must use unique canonical order"
            )
        }
        let target = try container.decode(
            RuntimeReceiptTargetRecord.self,
            forKey: .target
        ).target
        self.init(
            target: target,
            objectDigest: objectDigest,
            requiredSymbols: requiredSymbols,
            systemDependencies: systemDependencies,
            libraries: libraries
        )
    }
}

private struct RuntimeReceiptDynamicCodingKey: CodingKey {
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

private struct RuntimeReceiptTargetRecord: Decodable {
    let target: MojoTargetConfiguration

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case triple
        case cpu
        case accelerator
    }

    init(from decoder: Decoder) throws {
        try requireRuntimeReceiptKeys(
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

private func requireRuntimeReceiptKeys(
    required: Set<String>,
    allowed: Set<String>,
    decoder: Decoder
) throws {
    let container = try decoder.container(
        keyedBy: RuntimeReceiptDynamicCodingKey.self
    )
    let actual = Set(container.allKeys.map(\.stringValue))
    let missing = required.subtracting(actual)
    let unknown = actual.subtracting(allowed)
    guard missing.isEmpty, unknown.isEmpty else {
        throw MojoArtifactError.invalidRuntimeReceipt(
            "closed record key mismatch; missing=\(missing.sorted()), unknown=\(unknown.sorted())"
        )
    }
}

private func isRuntimeReceiptDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

private func isCanonicalRuntimeReceiptList(_ values: [String]) -> Bool {
    values.allSatisfy { !$0.isEmpty }
        && values == values.sorted()
        && Set(values).count == values.count
}
