import Foundation
import PackagePlugin

@main
struct MojoBuildPlugin: BuildToolPlugin {
    private struct PreparedManifest: Decodable {
        struct ArtifactIdentity: Decodable {
            let artifactName: String
        }

        let schemaVersion: Int
        let artifactIdentity: ArtifactIdentity?
    }

    private struct PackageConfiguration: Decodable {
        struct Target: Decodable {
            let mojoPackages: [String]
        }

        let targets: [String: Target]
    }

    private struct TargetConfiguration {
        let triple: String
        let cpu: String
        let accelerator: String?

        init(environment: [String: String]) throws {
            let triple = environment["SWIFT_MOJO_TARGET_TRIPLE"]
                ?? Self.defaultTriple
            let cpu = environment["SWIFT_MOJO_TARGET_CPU"] ?? "generic"
            let accelerator = environment["SWIFT_MOJO_TARGET_ACCELERATOR"]
            guard Self.isValid(triple, allowedPunctuation: [45, 46, 95]) else {
                throw ConfigurationError.invalidEnvironmentVariable(
                    name: "SWIFT_MOJO_TARGET_TRIPLE",
                    value: triple
                )
            }
            guard Self.isValid(cpu, allowedPunctuation: [43, 45, 46, 95]) else {
                throw ConfigurationError.invalidEnvironmentVariable(
                    name: "SWIFT_MOJO_TARGET_CPU",
                    value: cpu
                )
            }
            if let accelerator,
               !Self.isValid(
                    accelerator,
                    allowedPunctuation: [43, 45, 46, 58, 95]
               ) {
                throw ConfigurationError.invalidEnvironmentVariable(
                    name: "SWIFT_MOJO_TARGET_ACCELERATOR",
                    value: accelerator
                )
            }
            self.triple = triple
            self.cpu = cpu
            self.accelerator = accelerator
        }

        static func resolve(
            environment: [String: String],
            useHostDefault: Bool
        ) throws -> TargetConfiguration? {
            let hasOverride = [
                "SWIFT_MOJO_TARGET_TRIPLE",
                "SWIFT_MOJO_TARGET_CPU",
                "SWIFT_MOJO_TARGET_ACCELERATOR",
            ].contains { environment[$0] != nil }
            guard useHostDefault || hasOverride else {
                return nil
            }
            return try TargetConfiguration(environment: environment)
        }

        private static var defaultTriple: String {
#if arch(arm64) && os(macOS)
            "arm64-apple-macosx14.0"
#elseif arch(x86_64) && os(macOS)
            "x86_64-apple-macosx14.0"
#else
            "unsupported-host"
#endif
        }

        private static func isValid(
            _ value: String,
            allowedPunctuation: Set<UInt8>
        ) -> Bool {
            !value.isEmpty && value.utf8.allSatisfy { codeUnit in
                (codeUnit >= 48 && codeUnit <= 57)
                    || (codeUnit >= 65 && codeUnit <= 90)
                    || (codeUnit >= 97 && codeUnit <= 122)
                    || allowedPunctuation.contains(codeUnit)
            }
        }
    }

    private enum ConfigurationError: Error, CustomStringConvertible {
        case invalidEnvironmentVariable(name: String, value: String)
        case multiplePreparedArtifacts(String)
        case missingTargetConfiguration(String)

        var description: String {
            switch self {
            case .invalidEnvironmentVariable(let name, let value):
                "\(name) contains an unsupported value: '\(value)'"
            case .multiplePreparedArtifacts(let directory):
                "Multiple XCFrameworks exist in '\(directory)'; keep only the target-scoped artifact"
            case .missingTargetConfiguration(let target):
                "SwiftMojo.json does not declare target '\(target)'"
            }
        }
    }

    func createBuildCommands(
        context: PluginContext,
        target: any Target
    ) async throws -> [Command] {
        guard let sourceTarget = target.sourceModule else {
            Diagnostics.error("MojoBuildPlugin requires a source module target")
            return []
        }

        let configurationURL = context.package.directoryURL
            .appendingPathComponent("SwiftMojo.json")
        let hasPackageConfiguration = FileManager.default.fileExists(
            atPath: configurationURL.path
        )
        let configuration: TargetConfiguration?
        do {
            configuration = try TargetConfiguration.resolve(
                environment: ProcessInfo.processInfo.environment,
                useHostDefault: !hasPackageConfiguration
            )
        } catch {
            Diagnostics.error(String(describing: error))
            return []
        }

        let verifier = try context.tool(named: "swift-mojo")
        let sources = sourceTarget.sourceFiles(withSuffix: "swift")
            .map(\.url)
            .sorted { $0.path < $1.path }
        let generatedDirectory = context.package.directoryURL
            .appendingPathComponent("Generated", isDirectory: true)
            .appendingPathComponent(target.name, isDirectory: true)
        let manifest = generatedDirectory.appendingPathComponent(
            "MojoArtifact.json"
        )
        let preparedManifest = try Self.preparedManifest(at: manifest)
        let artifactName = try preparedManifest?.artifactIdentity?.artifactName
            ?? Self.discoverArtifactName(
                in: generatedDirectory,
                targetName: target.name
            )
        let artifact = generatedDirectory.appendingPathComponent(
            artifactName,
            isDirectory: true
        )
        let externalPackages = try Self.externalPackageURLs(
            configurationURL: configurationURL,
            packageRootURL: context.package.directoryURL,
            targetName: target.name
        )
        let externalInputs = try externalPackages.flatMap {
            try Self.treeInputs(at: $0)
        }
        let artifactInputs = try Self.artifactInputs(at: artifact)
        let sourceMap = generatedDirectory.appendingPathComponent(
            "MojoSourceMap.json"
        )
        let generatedMojoSource = generatedDirectory.appendingPathComponent(
            "Bindings.mojo"
        )
        let generatedSource = context.pluginWorkDirectoryURL
            .appendingPathComponent("SwiftMojoBindings.generated.swift")

        var arguments = [
            "verify",
            "--output-dir", generatedDirectory.path,
            "--generated-source", generatedSource.path,
            "--source-root", context.package.directoryURL.path,
        ]
        if let configuration {
            arguments.append(
                contentsOf: [
                    "--target-triple", configuration.triple,
                    "--target-cpu", configuration.cpu,
                ]
            )
            if let accelerator = configuration.accelerator {
                arguments.append(
                    contentsOf: ["--target-accelerator", accelerator]
                )
            }
        }
        if hasPackageConfiguration {
            arguments.append(
                contentsOf: [
                    "--configuration", configurationURL.path,
                    "--target-name", target.name,
                ]
            )
        }
        for source in sources {
            arguments.append(contentsOf: ["--source", source.path])
        }
        for externalPackage in externalPackages {
            arguments.append(
                contentsOf: ["--mojo-package", externalPackage.path]
            )
        }

        var inputs = sources + [manifest] + artifactInputs + externalInputs
        if hasPackageConfiguration {
            inputs.append(configurationURL)
        }
        if preparedManifest?.schemaVersion ?? 0 >= 4 {
            inputs.append(sourceMap)
            inputs.append(generatedMojoSource)
        }

        return [
            .buildCommand(
                displayName: "Verify prepared Mojo bindings for \(target.name)",
                executable: verifier.url,
                arguments: arguments,
                inputFiles: inputs,
                outputFiles: [generatedSource]
            ),
        ]
    }

    private static func artifactInputs(at artifact: URL) throws -> [URL] {
        try treeInputs(at: artifact)
    }

    private static func treeInputs(at root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return [root]
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        ) else {
            return [root]
        }

        var inputs = [root]
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isDirectoryKey, .isRegularFileKey]
            )
            if values.isDirectory == true || values.isRegularFile == true {
                inputs.append(url)
            }
        }
        return inputs.sorted { $0.path < $1.path }
    }

    private static func preparedManifest(
        at url: URL
    ) throws -> PreparedManifest? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try JSONDecoder().decode(
            PreparedManifest.self,
            from: Data(contentsOf: url)
        )
    }

    private static func externalPackageURLs(
        configurationURL: URL,
        packageRootURL: URL,
        targetName: String
    ) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            return []
        }
        let configuration = try JSONDecoder().decode(
            PackageConfiguration.self,
            from: Data(contentsOf: configurationURL)
        )
        guard let target = configuration.targets[targetName] else {
            throw ConfigurationError.missingTargetConfiguration(targetName)
        }
        return target.mojoPackages.sorted().map {
            packageRootURL
                .appendingPathComponent("Mojo", isDirectory: true)
                .appendingPathComponent($0, isDirectory: true)
        }
    }

    private static func moduleComponent(_ targetName: String) -> String {
        String(targetName.map { character in
            character.isLetter || character.isNumber || character == "_"
                ? character
                : "_"
        })
    }

    private static func discoverArtifactName(
        in generatedDirectory: URL,
        targetName: String
    ) throws -> String {
        guard FileManager.default.fileExists(
            atPath: generatedDirectory.path
        ) else {
            return "SwiftMojo_\(moduleComponent(targetName))_ABI.xcframework"
        }
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: generatedDirectory,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { url in
            guard url.pathExtension == "xcframework" else {
                return false
            }
            return (try url.resourceValues(forKeys: [.isDirectoryKey]))
                .isDirectory == true
        }
        guard artifacts.count <= 1 else {
            throw ConfigurationError.multiplePreparedArtifacts(
                generatedDirectory.path
            )
        }
        return artifacts.first?.lastPathComponent
            ?? "SwiftMojo_\(moduleComponent(targetName))_ABI.xcframework"
    }
}
