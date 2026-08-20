import Foundation
import MojoArtifactCore
import MojoCompilerCore

package struct MojoCommandRunner: Sendable {
    private enum OutputFormat: String {
        case text
        case json
    }

    private struct ParsedOptions {
        let values: [String: [String]]

        init(arguments: [String]) throws {
            var values: [String: [String]] = [:]
            var index = arguments.startIndex
            while index < arguments.endIndex {
                let option = arguments[index]
                guard option.hasPrefix("--") else {
                    throw MojoArtifactError.invalidArguments(
                        "Unexpected positional argument '\(option)'"
                    )
                }
                let valueIndex = arguments.index(after: index)
                guard valueIndex < arguments.endIndex,
                      !arguments[valueIndex].hasPrefix("--") else {
                    throw MojoArtifactError.invalidArguments(
                        "Missing value for \(option)"
                    )
                }
                values[option, default: []].append(arguments[valueIndex])
                index = arguments.index(after: valueIndex)
            }
            self.values = values
        }

        func value(_ option: String) -> String? {
            values[option]?.last
        }

        func urls(_ option: String) -> [URL] {
            (values[option] ?? []).map {
                URL(fileURLWithPath: $0).standardizedFileURL
            }
        }

        func requiredURL(_ option: String) throws -> URL {
            guard let value = value(option) else {
                throw MojoArtifactError.invalidArguments(
                    "Missing required option \(option)"
                )
            }
            return URL(fileURLWithPath: value).standardizedFileURL
        }

        func packageLayoutIfPresent(
            currentDirectoryURL: URL
        ) throws -> MojoPackageLayout? {
            let packageRoot = value("--package-root")
            let target = value("--target")
            guard packageRoot != nil || target != nil else {
                return nil
            }
            guard let target else {
                throw MojoArtifactError.invalidArguments(
                    "--target is required when --package-root is used"
                )
            }
            let rootURL = packageRoot.map(URL.init(fileURLWithPath:))
                ?? currentDirectoryURL
            return try MojoPackageLayout(
                packageRootURL: rootURL,
                targetName: target
            )
        }

        func rejectUnknown(allowed: Set<String>) throws {
            let unknown = Set(values.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                throw MojoArtifactError.invalidArguments(
                    "Unknown option(s): \(unknown.sorted().joined(separator: ", "))"
                )
            }
            let repeatable: Set<String> = ["--source", "--mojo-package"]
            for (option, optionValues) in values
            where !repeatable.contains(option) && optionValues.count > 1 {
                throw MojoArtifactError.invalidArguments(
                    "Option \(option) may be supplied only once"
                )
            }
        }
    }

    package static let version = "0.2.0-dev"

    private let environment: [String: String]
    private let currentDirectoryURL: URL

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath
        )
    ) {
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL.standardizedFileURL
    }

    package func run(arguments: [String]) -> MojoCommandResult {
        let command = arguments.first ?? "help"
        let requestedFormat = Self.requestedFormat(arguments: arguments)
        do {
            return try execute(
                command: command,
                arguments: Array(arguments.dropFirst()),
                format: requestedFormat
            )
        } catch {
            return failure(
                command: command,
                error: error,
                format: requestedFormat
            )
        }
    }

    private func execute(
        command: String,
        arguments: [String],
        format: OutputFormat
    ) throws -> MojoCommandResult {
        let options = try ParsedOptions(arguments: arguments)
        if let rawFormat = options.value("--format"),
           OutputFormat(rawValue: rawFormat) == nil {
            throw MojoArtifactError.invalidArguments(
                "Unsupported --format '\(rawFormat)'; expected text or json"
            )
        }
        switch command {
        case "init":
            return try initialize(options: options, format: format)
        case "prepare":
            return try prepare(options: options, format: format)
        case "verify":
            return try verify(options: options, format: format)
        case "inspect":
            return try inspect(options: options, format: format)
        case "doctor":
            return try doctor(options: options, format: format)
        case "release":
            return try release(options: options, format: format)
        case "version", "--version":
            try options.rejectUnknown(allowed: ["--format"])
            return try success(
                command: "version",
                message: Self.version,
                json: MojoCommandJSONOutput(
                    success: true,
                    command: "version",
                    message: Self.version
                ),
                format: format
            )
        case "help", "--help", "-h":
            return MojoCommandResult(
                exitCode: 0,
                standardOutput: Self.usage + "\n"
            )
        default:
            throw MojoArtifactError.invalidArguments(
                "Unknown command '\(command)'.\n\n\(Self.usage)"
            )
        }
    }

    private func initialize(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--output-dir", "--package-root", "--target",
                "--artifact-id", "--format",
            ]
        )
        let layout = try options.packageLayoutIfPresent(
            currentDirectoryURL: currentDirectoryURL
        )
        let output: URL
        let identity: MojoArtifactIdentity
        if let layout {
            guard options.value("--output-dir") == nil,
                  options.value("--artifact-id") == nil else {
                throw MojoArtifactError.invalidArguments(
                    "Package layout mode derives output and artifact identity"
                )
            }
            try layout.validatePackageTarget()
            output = layout.outputDirectoryURL
            identity = layout.identity
        } else {
            output = try options.requiredURL("--output-dir")
            identity = try MojoArtifactIdentity(
                targetName: options.value("--artifact-id") ?? "Standalone"
            )
        }
        let disposition = try MojoArtifactInitializer().initialize(
            outputDirectoryURL: output,
            identity: identity
        )
        var message = "\(disposition == .initialized ? "Initialized" : "Already initialized") \(identity.moduleName) at \(output.path)."
        if let layout {
            message += """


            Add this binary target to Package.swift:
              .binaryTarget(name: "\(identity.moduleName)", path: "\(layout.binaryTargetRelativePath)")
            Then make target "\(layout.targetName)" depend on "\(identity.moduleName)" and apply MojoBuildPlugin.
            """
        }
        return try success(
            command: "init",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "init",
                message: message,
                target: layout?.targetName,
                module: identity.moduleName
            ),
            format: format
        )
    }

    private func prepare(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--source", "--source-root", "--mojo-package",
                "--output-dir", "--artifact-id", "--target-triple",
                "--target-cpu", "--target-accelerator", "--package-root",
                "--target", "--format",
            ]
        )
        let layout = try options.packageLayoutIfPresent(
            currentDirectoryURL: currentDirectoryURL
        )
        let prepareOptions: MojoPrepareOptions
        if let layout {
            guard options.urls("--source").isEmpty,
                  options.urls("--mojo-package").isEmpty,
                  options.value("--output-dir") == nil,
                  options.value("--artifact-id") == nil else {
                throw MojoArtifactError.invalidArguments(
                    "Package layout mode discovers Swift and Mojo sources"
                )
            }
            if let configuration = try optionalConfiguration(
                packageRootURL: layout.packageRootURL
            ) {
                guard options.value("--target-triple") == nil,
                      options.value("--target-cpu") == nil,
                      options.value("--target-accelerator") == nil else {
                    throw MojoArtifactError.invalidArguments(
                        "SwiftMojo.json owns release slices; command-line target overrides are not allowed"
                    )
                }
                let target = try configuration.target(named: layout.targetName)
                prepareOptions = try MojoPrepareOptions(
                    sourceURLs: layout.sourceURLs(),
                    sourceRootURL: layout.packageRootURL,
                    externalPackages: layout.externalPackages(
                        names: target.mojoPackages
                    ),
                    outputDirectoryURL: layout.outputDirectoryURL,
                    identity: layout.identity,
                    targets: target.slices,
                    expectedCompilerVersion: target.compilerVersion
                )
            } else {
                prepareOptions = try MojoPrepareOptions(
                    sourceURLs: layout.sourceURLs(),
                    sourceRootURL: layout.packageRootURL,
                    outputDirectoryURL: layout.outputDirectoryURL,
                    identity: layout.identity,
                    targets: [try target(options: options)]
                )
            }
        } else {
            let externalPackages = try options.urls("--mojo-package").map {
                try MojoExternalPackage(
                    name: $0.lastPathComponent,
                    rootURL: $0
                )
            }
            prepareOptions = try MojoPrepareOptions(
                sourceURLs: options.urls("--source"),
                sourceRootURL: options.value("--source-root").map {
                    URL(fileURLWithPath: $0)
                },
                externalPackages: externalPackages,
                outputDirectoryURL: options.requiredURL("--output-dir"),
                identity: MojoArtifactIdentity(
                    targetName: options.value("--artifact-id") ?? "Standalone"
                ),
                targets: [try target(options: options)]
            )
        }
        let result = try MojoArtifactPreparer(
            environment: environment
        ).prepare(options: prepareOptions)
        let manifest = result.manifest
        let message = "\(result.disposition == .reused ? "Reused" : "Prepared") \(manifest.bindings.count) binding(s) across \(manifest.effectiveSlices.count) slice(s)."
        return try success(
            command: "prepare",
            message: message,
            json: manifestOutput(
                command: "prepare",
                message: message,
                target: layout?.targetName,
                manifest: manifest
            ),
            format: format
        )
    }

    private func verify(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--source", "--source-root", "--mojo-package",
                "--output-dir", "--generated-source", "--target-triple",
                "--target-cpu", "--target-accelerator", "--configuration",
                "--target-name", "--format",
            ]
        )
        let externalPackages = try options.urls("--mojo-package").map {
            try MojoExternalPackage(name: $0.lastPathComponent, rootURL: $0)
        }
        let expectedIdentity: MojoArtifactIdentity?
        let expectedCompilerVersion: String?
        let expectedSlices: [MojoTargetConfiguration]?
        if let configurationPath = options.value("--configuration") {
            guard let targetName = options.value("--target-name") else {
                throw MojoArtifactError.invalidArguments(
                    "--target-name is required with --configuration"
                )
            }
            let configuration = try SwiftMojoConfiguration.load(
                configurationURL: URL(fileURLWithPath: configurationPath)
            )
            let configuredTarget = try configuration.target(named: targetName)
            expectedIdentity = try MojoArtifactIdentity(targetName: targetName)
            expectedCompilerVersion = configuredTarget.compilerVersion
            expectedSlices = configuredTarget.slices
        } else {
            guard options.value("--target-name") == nil else {
                throw MojoArtifactError.invalidArguments(
                    "--configuration is required with --target-name"
                )
            }
            expectedIdentity = nil
            expectedCompilerVersion = nil
            expectedSlices = nil
        }
        let requestedTarget: MojoTargetConfiguration?
        let hasExplicitTarget = options.value("--target-triple") != nil
            || options.value("--target-cpu") != nil
            || options.value("--target-accelerator") != nil
        if expectedSlices == nil || hasExplicitTarget {
            requestedTarget = try target(options: options)
        } else {
            requestedTarget = nil
        }
        let verifyOptions = try MojoVerifyOptions(
            sourceURLs: options.urls("--source"),
            sourceRootURL: options.value("--source-root").map {
                URL(fileURLWithPath: $0)
            },
            externalPackages: externalPackages,
            outputDirectoryURL: options.requiredURL("--output-dir"),
            generatedSourceURL: options.requiredURL("--generated-source"),
            target: requestedTarget,
            expectedIdentity: expectedIdentity,
            expectedCompilerVersion: expectedCompilerVersion,
            expectedSlices: expectedSlices
        )
        let manifest = try MojoArtifactVerifier().verify(options: verifyOptions)
        let message = "Verified \(manifest.bindings.count) binding(s); artifact SHA-256 \(manifest.artifactDigest)."
        return try success(
            command: "verify",
            message: message,
            json: manifestOutput(
                command: "verify",
                message: message,
                target: nil,
                manifest: manifest
            ),
            format: format
        )
    }

    private func inspect(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: ["--package-root", "--target", "--format"]
        )
        let layout = try requiredLayout(options: options)
        let report = try MojoArtifactInspector().inspect(
            layout: layout,
            configuration: optionalConfiguration(
                packageRootURL: layout.packageRootURL
            )
        )
        let message = "Inspected \(report.bindingCount) binding(s) for \(report.moduleName)."
        let text = "\(message)\n\n\(report.generatedMojo)"
        return try success(
            command: "inspect",
            message: text,
            json: MojoCommandJSONOutput(
                success: true,
                command: "inspect",
                message: message,
                target: report.targetName,
                module: report.moduleName,
                inputGraphDigest: report.inputGraphDigest,
                artifactDigest: report.preparedManifest?.artifactDigest,
                bindingCount: report.bindingCount,
                generatedMojo: report.generatedMojo
            ),
            format: format
        )
    }

    private func doctor(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: ["--package-root", "--target", "--format"]
        )
        let layout = try options.packageLayoutIfPresent(
            currentDirectoryURL: currentDirectoryURL
        )
        let report = MojoDoctor(environment: environment).diagnose(layout: layout)
        let lines = report.checks.map {
            "[\($0.status == .passed ? "PASS" : "FAIL")] \($0.name): \($0.detail)"
        }
        let message = lines.joined(separator: "\n")
        let json = MojoCommandJSONOutput(
            success: report.isHealthy,
            command: "doctor",
            message: report.isHealthy
                ? "All required checks passed"
                : "One or more required checks failed",
            target: layout?.targetName,
            checks: report.checks
        )
        if report.isHealthy {
            return try success(
                command: "doctor",
                message: message,
                json: json,
                format: format
            )
        }
        return try formattedResult(
            exitCode: 1,
            textError: message,
            json: json,
            format: format
        )
    }

    private func release(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: ["--package-root", "--target", "--format"]
        )
        let layout = try requiredLayout(options: options)
        let report = try MojoReleaseVerifier().verify(
            layout: layout
        )
        let message = "Release verification passed for \(report.targetName): \(report.bindingCount) binding(s), \(report.slices.count) slice(s), artifact \(report.artifactDigest)."
        return try success(
            command: "release",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "release",
                message: message,
                target: report.targetName,
                module: report.moduleName,
                compilerVersion: report.compilerVersion,
                inputGraphDigest: report.inputGraphDigest,
                artifactDigest: report.artifactDigest,
                bindingCount: report.bindingCount,
                slices: report.slices.map { $0.target.identity },
                externalPackages: report.externalPackages.map(\.name)
            ),
            format: format
        )
    }

    private func requiredLayout(
        options: ParsedOptions
    ) throws -> MojoPackageLayout {
        guard let layout = try options.packageLayoutIfPresent(
            currentDirectoryURL: currentDirectoryURL
        ) else {
            throw MojoArtifactError.invalidArguments(
                "--target is required for this package command"
            )
        }
        return layout
    }

    private func optionalConfiguration(
        packageRootURL: URL
    ) throws -> SwiftMojoConfiguration? {
        let url = packageRootURL.appendingPathComponent(
            SwiftMojoConfiguration.fileName
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try SwiftMojoConfiguration.load(packageRootURL: packageRootURL)
    }

    private func target(
        options: ParsedOptions
    ) throws -> MojoTargetConfiguration {
        try MojoTargetConfiguration(
            triple: options.value("--target-triple") ?? Self.defaultTargetTriple,
            cpu: options.value("--target-cpu") ?? "generic",
            accelerator: options.value("--target-accelerator")
        )
    }

    private func manifestOutput(
        command: String,
        message: String,
        target: String?,
        manifest: MojoArtifactManifest
    ) -> MojoCommandJSONOutput {
        MojoCommandJSONOutput(
            success: true,
            command: command,
            message: message,
            target: target,
            module: manifest.effectiveIdentity.moduleName,
            compilerVersion: manifest.compilerVersion,
            inputGraphDigest: manifest.inputGraphDigest
                ?? manifest.sourceGraphDigest,
            artifactDigest: manifest.artifactDigest,
            bindingCount: manifest.bindings.count,
            slices: manifest.effectiveSlices.map { $0.target.identity },
            externalPackages: (manifest.externalPackages ?? []).map(\.name)
        )
    }

    private func success(
        command: String,
        message: String,
        json: MojoCommandJSONOutput,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try formattedResult(
            exitCode: 0,
            textOutput: message,
            json: json,
            format: format
        )
    }

    private func formattedResult(
        exitCode: Int32,
        textOutput: String = "",
        textError: String = "",
        json: MojoCommandJSONOutput,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        switch format {
        case .text:
            return MojoCommandResult(
                exitCode: exitCode,
                standardOutput: textOutput.isEmpty ? "" : textOutput + "\n",
                standardError: textError.isEmpty ? "" : textError + "\n"
            )
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(json)
            guard let string = String(data: data, encoding: .utf8) else {
                throw MojoArtifactError.invalidArguments(
                    "Failed to encode command output as UTF-8 JSON"
                )
            }
            return MojoCommandResult(
                exitCode: exitCode,
                standardOutput: string + "\n"
            )
        }
    }

    private func failure(
        command: String,
        error: Error,
        format: OutputFormat
    ) -> MojoCommandResult {
        let message = String(describing: error)
        let json = MojoCommandJSONOutput(
            success: false,
            command: command,
            message: message
        )
        do {
            return try formattedResult(
                exitCode: 1,
                textError: "error: \(message)",
                json: json,
                format: format
            )
        } catch {
            return MojoCommandResult(
                exitCode: 1,
                standardError: "error: \(message)\n"
            )
        }
    }

    private static func requestedFormat(arguments: [String]) -> OutputFormat {
        guard let index = arguments.firstIndex(of: "--format"),
              arguments.indices.contains(index + 1) else {
            return .text
        }
        return OutputFormat(rawValue: arguments[index + 1]) ?? .text
    }

    private static var defaultTargetTriple: String {
#if arch(arm64) && os(macOS)
        "arm64-apple-macosx14.0"
#elseif arch(x86_64) && os(macOS)
        "x86_64-apple-macosx14.0"
#else
        "unsupported-host"
#endif
    }

    package static let usage = """
    Usage:
      swift-mojo init --package-root <path> --target <target>
      swift-mojo prepare --package-root <path> --target <target>
      swift-mojo inspect --package-root <path> --target <target> [--format text|json]
      swift-mojo doctor [--package-root <path> --target <target>] [--format text|json]
      swift-mojo release --package-root <path> --target <target> [--format text|json]
      swift-mojo verify --source <file.swift> ... --output-dir <path> --generated-source <file.swift> [--mojo-package <directory> ...] [--source-root <path>] [--target-triple <triple>] [--target-cpu <cpu>] [--target-accelerator <accelerator>] [--format text|json]
      swift-mojo version [--format text|json]

    Package authoring commands are also available as:
      swift package mojo <command> --target <target>
    """
}
