import Foundation
import MojoCompilerCore

package struct SwiftMojoConfiguration: Codable, Equatable, Sendable {
    package struct Target: Codable, Equatable, Sendable {
        package let compilerVersion: String
        package let mojoPackages: [String]
        package let slices: [MojoTargetConfiguration]

        package init(
            compilerVersion: String,
            mojoPackages: [String],
            slices: [MojoTargetConfiguration]
        ) throws {
            guard !compilerVersion
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MojoArtifactError.invalidConfiguration(
                    "compilerVersion cannot be empty"
                )
            }
            guard !slices.isEmpty else {
                throw MojoArtifactError.invalidConfiguration(
                    "Each target requires at least one release slice"
                )
            }
            guard Set(mojoPackages).count == mojoPackages.count else {
                throw MojoArtifactError.invalidConfiguration(
                    "mojoPackages contains duplicate package names"
                )
            }
            guard Set(slices.map(\.identity)).count == slices.count else {
                throw MojoArtifactError.invalidConfiguration(
                    "slices contains duplicate target identities"
                )
            }
            try MojoNativeArtifactAdapter.validate(
                targets: slices,
                error: MojoArtifactError.invalidConfiguration
            )
            self.compilerVersion = compilerVersion
            self.mojoPackages = mojoPackages.sorted()
            self.slices = slices.sorted { $0.identity < $1.identity }
        }
    }

    package static let currentSchemaVersion = 1
    package static let fileName = "SwiftMojo.json"

    package let schemaVersion: Int
    package let targets: [String: Target]

    package init(targets: [String: Target]) throws {
        guard !targets.isEmpty else {
            throw MojoArtifactError.invalidConfiguration(
                "At least one Mojo-enabled target is required"
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.targets = targets
    }

    package static func load(packageRootURL: URL) throws -> Self {
        let url = packageRootURL.appendingPathComponent(fileName)
        return try load(configurationURL: url)
    }

    package static func load(configurationURL url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MojoArtifactError.configurationMissing(url.path)
        }
        do {
            try MojoRegularFile.validate(at: url)
            return try decode(Data(contentsOf: url))
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw MojoArtifactError.invalidConfiguration(
                String(describing: error)
            )
        }
    }

    package static func decode(_ data: Data) throws -> Self {
        try validateShape(data)
        let configuration: Self
        do {
            configuration = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw MojoArtifactError.invalidConfiguration(
                String(describing: error)
            )
        }
        guard configuration.schemaVersion == currentSchemaVersion else {
            throw MojoArtifactError.invalidConfiguration(
                "Unsupported configuration schema \(configuration.schemaVersion)"
            )
        }
        for (name, target) in configuration.targets {
            _ = try MojoArtifactIdentity(targetName: name)
            _ = try Target(
                compilerVersion: target.compilerVersion,
                mojoPackages: target.mojoPackages,
                slices: target.slices
            )
        }
        return configuration
    }

    private static func validateShape(_ data: Data) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw MojoArtifactError.invalidConfiguration(
                String(describing: error)
            )
        }
        guard let root = object as? [String: Any] else {
            throw MojoArtifactError.invalidConfiguration(
                "The root value must be an object"
            )
        }
        try validateKeys(
            Set(root.keys),
            allowed: ["schemaVersion", "targets"],
            context: "root"
        )
        guard let targets = root["targets"] as? [String: Any] else {
            throw MojoArtifactError.invalidConfiguration(
                "targets must be an object"
            )
        }
        for (targetName, value) in targets {
            guard let target = value as? [String: Any] else {
                throw MojoArtifactError.invalidConfiguration(
                    "Target '\(targetName)' must be an object"
                )
            }
            try validateKeys(
                Set(target.keys),
                allowed: ["compilerVersion", "mojoPackages", "slices"],
                context: "target '\(targetName)'"
            )
            guard let slices = target["slices"] as? [Any] else {
                throw MojoArtifactError.invalidConfiguration(
                    "Target '\(targetName)' slices must be an array"
                )
            }
            for (index, value) in slices.enumerated() {
                guard let slice = value as? [String: Any] else {
                    throw MojoArtifactError.invalidConfiguration(
                        "Target '\(targetName)' slice \(index) must be an object"
                    )
                }
                try validateKeys(
                    Set(slice.keys),
                    allowed: ["accelerator", "cpu", "triple"],
                    context: "target '\(targetName)' slice \(index)"
                )
            }
        }
    }

    private static func validateKeys(
        _ keys: Set<String>,
        allowed: Set<String>,
        context: String
    ) throws {
        let unknown = keys.subtracting(allowed)
        guard unknown.isEmpty else {
            throw MojoArtifactError.invalidConfiguration(
                "Unknown key(s) in \(context): \(unknown.sorted().joined(separator: ", "))"
            )
        }
    }

    package func target(named name: String) throws -> Target {
        guard let target = targets[name] else {
            throw MojoArtifactError.invalidConfiguration(
                "Target '\(name)' is not declared in \(Self.fileName)"
            )
        }
        return target
    }
}
