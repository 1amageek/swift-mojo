import Foundation
import PackagePlugin

@main
struct MojoBuildPlugin: BuildToolPlugin {
    private struct TargetConfiguration {
        let triple: String
        let cpu: String

        init(environment: [String: String]) throws {
            let triple = environment["SWIFT_MOJO_TARGET_TRIPLE"]
                ?? Self.defaultTriple
            let cpu = environment["SWIFT_MOJO_TARGET_CPU"] ?? "generic"
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
            self.triple = triple
            self.cpu = cpu
        }

        private static var defaultTriple: String {
#if arch(arm64) && os(macOS)
            "arm64-apple-macosx14.0"
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

        var description: String {
            switch self {
            case .invalidEnvironmentVariable(let name, let value):
                "\(name) contains an unsupported value: '\(value)'"
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

        let configuration: TargetConfiguration
        do {
            configuration = try TargetConfiguration(
                environment: ProcessInfo.processInfo.environment
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
        let artifact = generatedDirectory.appendingPathComponent(
            "GeneratedMojoABI.xcframework",
            isDirectory: true
        )
        let manifest = generatedDirectory.appendingPathComponent(
            "MojoArtifact.json"
        )
        let artifactInputs = try Self.artifactInputs(at: artifact)
        let generatedSource = context.pluginWorkDirectoryURL
            .appendingPathComponent("SwiftMojoBindings.generated.swift")

        var arguments = [
            "verify",
            "--output-dir", generatedDirectory.path,
            "--generated-source", generatedSource.path,
            "--target-triple", configuration.triple,
            "--target-cpu", configuration.cpu,
        ]
        for source in sources {
            arguments.append(contentsOf: ["--source", source.path])
        }

        return [
            .buildCommand(
                displayName: "Verify prepared Mojo bindings for \(target.name)",
                executable: verifier.url,
                arguments: arguments,
                inputFiles: sources + [manifest] + artifactInputs,
                outputFiles: [generatedSource]
            ),
        ]
    }

    private static func artifactInputs(at artifact: URL) throws -> [URL] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: artifact.path) else {
            return [artifact]
        }
        guard let enumerator = fileManager.enumerator(
            at: artifact,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [artifact]
        }

        var inputs = [artifact]
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
}
