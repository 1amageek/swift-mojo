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
            let repeatable: Set<String> = [
                "--mojo-package",
                "--runtime-library",
                "--source",
                "--system-library",
            ]
            for (option, optionValues) in values
            where !repeatable.contains(option) && optionValues.count > 1 {
                throw MojoArtifactError.invalidArguments(
                    "Option \(option) may be supplied only once"
                )
            }
        }
    }

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
        case "runtime-prepare":
            return try prepareRuntimeReceipt(
                options: options,
                format: format
            )
        case "runtime-verify":
            return try verifyRuntimeReceipt(
                options: options,
                format: format
            )
        case "runtime-bundle-prepare":
            return try prepareRuntimeBundle(
                options: options,
                format: format
            )
        case "runtime-bundle-verify":
            return try verifyRuntimeBundle(
                options: options,
                format: format
            )
        case "runtime-library-prepare":
            return try prepareRuntimeLibrary(
                options: options,
                format: format
            )
        case "runtime-library-verify":
            return try verifyRuntimeLibrary(
                options: options,
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
        let initializationTargets: [MojoTargetConfiguration]?
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
            initializationTargets = try optionalConfiguration(
                packageRootURL: layout.packageRootURL
            )?.target(named: layout.targetName).slices
        } else {
            output = try options.requiredURL("--output-dir")
            identity = try MojoArtifactIdentity(
                targetName: options.value("--artifact-id") ?? "Standalone"
            )
            initializationTargets = nil
        }
        let disposition = try MojoArtifactInitializer().initialize(
            outputDirectoryURL: output,
            identity: identity,
            targets: initializationTargets
        )
        var message = "\(disposition == .initialized ? "Initialized" : "Already initialized") \(identity.moduleName) at \(output.path)."
        if let layout {
            let integrations: [MojoPackageBinaryIntegration]
            if let initializationTargets {
                integrations = try layout.binaryIntegrations(
                    targets: initializationTargets
                )
            } else {
                integrations = [
                    MojoPackageBinaryIntegration(
                        adapter: .appleXCFramework,
                        binaryTargetName: identity.moduleName,
                        binaryTargetPath: layout.binaryTargetRelativePath,
                        platforms: []
                    ),
                ]
            }
            let binaryTargets = integrations.map { integration in
                "  .binaryTarget(name: \"\(integration.binaryTargetName)\", path: \"\(integration.binaryTargetPath)\")"
            }.joined(separator: "\n")
            let dependencies = integrations.map { integration in
                guard !integration.platforms.isEmpty else {
                    return "  \"\(integration.binaryTargetName)\""
                }
                let platforms = integration.platforms.sorted().map {
                    ".\($0)"
                }.joined(separator: ", ")
                return "  .target(name: \"\(integration.binaryTargetName)\", condition: .when(platforms: [\(platforms)]))"
            }.joined(separator: ",\n")
            message += """


            Add these binary targets to Package.swift:
            \(binaryTargets)
            Add these dependencies to target "\(layout.targetName)":
            \(dependencies)
            Then apply MojoBuildPlugin to target "\(layout.targetName)".
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
            guard options.urls("--mojo-package").isEmpty,
                  options.value("--output-dir") == nil,
                  options.value("--artifact-id") == nil else {
                throw MojoArtifactError.invalidArguments(
                    "Package layout mode receives SwiftPM-resolved Swift sources and discovers Mojo packages"
                )
            }
            let sourceURLs = try resolvedPackageSources(
                options: options,
                layout: layout
            )
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
                    sourceURLs: sourceURLs,
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
                    sourceURLs: sourceURLs,
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
            allowed: [
                "--package-root", "--target", "--source", "--source-root",
                "--format",
            ]
        )
        let layout = try requiredLayout(options: options)
        let report = try MojoArtifactInspector().inspect(
            layout: layout,
            configuration: optionalConfiguration(
                packageRootURL: layout.packageRootURL
            ),
            sourceURLs: resolvedPackageSources(
                options: options,
                layout: layout
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
            allowed: [
                "--package-root", "--target", "--source", "--source-root",
                "--format",
            ]
        )
        let layout = try requiredLayout(options: options)
        let report = try MojoReleaseVerifier().verify(
            layout: layout,
            sourceURLs: resolvedPackageSources(
                options: options,
                layout: layout
            )
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

    private func prepareRuntimeReceipt(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--format", "--object", "--receipt", "--runtime-library",
                "--system-library", "--target-accelerator", "--target-cpu",
                "--target-triple",
            ]
        )
        let receiptURL = try options.requiredURL("--receipt")
        let runtimeOptions = try runtimeReceiptOptions(options: options)
        try validateRuntimeReceiptDestination(
            receiptURL,
            options: runtimeOptions
        )
        let receipt = try MojoRuntimeReceiptPreparer(
            environment: environment
        ).prepare(options: runtimeOptions)
        try FileManager.default.createDirectory(
            at: receiptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try receipt.encoded().write(to: receiptURL, options: .atomic)
        try MojoRegularFile.validate(at: receiptURL)
        let message = "Prepared runtime receipt \(receipt.digest) for \(receipt.libraries.count) library(s)."
        return try success(
            command: "runtime-prepare",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-prepare",
                message: message,
                target: receipt.target.identity,
                artifactDigest: receipt.digest,
                runtimeLibraries: receipt.libraries.map(\.fileName)
            ),
            format: format
        )
    }

    private func verifyRuntimeReceipt(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--format", "--object", "--receipt", "--runtime-library",
                "--system-library", "--target-accelerator", "--target-cpu",
                "--target-triple",
            ]
        )
        let receiptURL = try options.requiredURL("--receipt")
        try MojoRegularFile.validate(at: receiptURL)
        let receipt = try MojoRuntimeDependencyReceipt.decode(
            Data(contentsOf: receiptURL)
        )
        let verified = try MojoRuntimeReceiptVerifier(
            environment: environment
        ).verify(
            receipt: receipt,
            options: runtimeReceiptOptions(options: options)
        )
        let message = "Verified runtime receipt \(verified.digest) for \(verified.libraries.count) library(s)."
        return try success(
            command: "runtime-verify",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-verify",
                message: message,
                target: verified.target.identity,
                artifactDigest: verified.digest,
                runtimeLibraries: verified.libraries.map(\.fileName)
            ),
            format: format
        )
    }

    private func runtimeReceiptOptions(
        options: ParsedOptions
    ) throws -> MojoRuntimeReceiptOptions {
        try MojoRuntimeReceiptOptions(
            objectURL: options.requiredURL("--object"),
            libraryURLs: options.urls("--runtime-library"),
            target: target(options: options),
            allowedSystemDependencies: Set(
                options.values["--system-library"] ?? []
            )
        )
    }

    private func prepareRuntimeBundle(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--executable-name", "--format", "--object", "--output",
                "--receipt", "--runtime-library", "--system-library",
                "--target-accelerator", "--target-cpu", "--target-triple",
            ]
        )
        guard let executableName = options.value("--executable-name") else {
            throw MojoArtifactError.invalidArguments(
                "Missing required option --executable-name"
            )
        }
        let receiptURL = try options.requiredURL("--receipt")
        let outputURL = try options.requiredURL("--output")
        try MojoRegularFile.validate(at: receiptURL)
        try validateRuntimeBundleReceiptSource(
            receiptURL,
            outputURL: outputURL
        )
        let receipt = try MojoRuntimeDependencyReceipt.decode(
            Data(contentsOf: receiptURL)
        )
        let runtimeOptions = try runtimeReceiptOptions(options: options)
        let bundleOptions = try MojoRuntimeBundleOptions(
            outputDirectoryURL: outputURL,
            executableName: executableName,
            objectURL: runtimeOptions.objectURL,
            libraryURLs: runtimeOptions.libraryURLs,
            target: runtimeOptions.target,
            allowedSystemDependencies: runtimeOptions.allowedSystemDependencies
        )
        let manifest = try MojoRuntimeBundleBuilder(
            environment: environment
        ).prepare(
            receipt: receipt,
            options: bundleOptions
        )
        let message = "Prepared runtime bundle \(manifest.digest) at \(outputURL.path)."
        return try success(
            command: "runtime-bundle-prepare",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-bundle-prepare",
                message: message,
                target: manifest.target.identity,
                artifactDigest: manifest.digest,
                runtimeLibraries: manifest.libraries.map {
                    URL(fileURLWithPath: $0.relativePath).lastPathComponent
                },
                bundlePath: outputURL.path,
                executable: manifest.executable.relativePath
            ),
            format: format
        )
    }

    private func verifyRuntimeBundle(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(allowed: ["--bundle", "--format"])
        let bundleURL = try options.requiredURL("--bundle")
        let manifest = try MojoRuntimeBundleVerifier(
            environment: environment
        ).verify(bundleURL: bundleURL)
        let message = "Verified runtime bundle \(manifest.digest) at \(bundleURL.path)."
        return try success(
            command: "runtime-bundle-verify",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-bundle-verify",
                message: message,
                target: manifest.target.identity,
                artifactDigest: manifest.digest,
                runtimeLibraries: manifest.libraries.map {
                    URL(fileURLWithPath: $0.relativePath).lastPathComponent
                },
                bundlePath: bundleURL.path,
                executable: manifest.executable.relativePath
            ),
            format: format
        )
    }

    private func prepareRuntimeLibrary(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(
            allowed: [
                "--artifact-id", "--format", "--mojo-package", "--output",
                "--package-root", "--runtime-library", "--source",
                "--source-root", "--system-library", "--target",
                "--target-accelerator", "--target-cpu", "--target-triple",
            ]
        )
        let outputURL = try options.requiredURL("--output")
        let runtimeTarget = try target(options: options)
        guard runtimeTarget.accelerator != nil else {
            throw MojoArtifactError.invalidArguments(
                "runtime-library-prepare requires --target-accelerator"
            )
        }
        let layout = try options.packageLayoutIfPresent(
            currentDirectoryURL: currentDirectoryURL
        )
        let prepareOptions: MojoPrepareOptions
        if let layout {
            guard options.urls("--mojo-package").isEmpty,
                  options.value("--artifact-id") == nil else {
                throw MojoArtifactError.invalidArguments(
                    "Package runtime-library mode derives artifact identity and Mojo packages"
                )
            }
            let sourceURLs = try resolvedPackageSources(
                options: options,
                layout: layout
            )
            let configuredTarget = try optionalConfiguration(
                packageRootURL: layout.packageRootURL
            )?.target(named: layout.targetName)
            prepareOptions = try MojoPrepareOptions(
                sourceURLs: sourceURLs,
                sourceRootURL: layout.packageRootURL,
                externalPackages: layout.externalPackages(
                    names: configuredTarget?.mojoPackages ?? []
                ),
                outputDirectoryURL: outputURL,
                identity: layout.identity,
                targets: [runtimeTarget],
                expectedCompilerVersion: configuredTarget?.compilerVersion
            )
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
                outputDirectoryURL: outputURL,
                identity: MojoArtifactIdentity(
                    targetName: options.value("--artifact-id")
                        ?? "StandaloneRuntime"
                ),
                targets: [runtimeTarget]
            )
        }
        let manifest = try MojoRuntimeLibraryArtifactPreparer(
            environment: environment
        ).prepare(
            options: prepareOptions,
            runtimeLibraryURLs: options.urls("--runtime-library"),
            allowedSystemDependencies: Set(
                options.values["--system-library"] ?? []
            )
        )
        let message = "Prepared generated runtime library \(manifest.digest) at \(outputURL.path)."
        return try success(
            command: "runtime-library-prepare",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-library-prepare",
                message: message,
                target: manifest.target.identity,
                module: manifest.moduleName,
                compilerVersion: manifest.compilerVersion,
                inputGraphDigest: manifest.inputGraphDigest,
                artifactDigest: manifest.digest,
                runtimeLibraries: manifest.runtimeLibraries.map {
                    URL(fileURLWithPath: $0.relativePath).lastPathComponent
                },
                bundlePath: outputURL.path,
                library: manifest.library.relativePath
            ),
            format: format
        )
    }

    private func verifyRuntimeLibrary(
        options: ParsedOptions,
        format: OutputFormat
    ) throws -> MojoCommandResult {
        try options.rejectUnknown(allowed: ["--bundle", "--format"])
        let bundleURL = try options.requiredURL("--bundle")
        let manifest = try MojoRuntimeLibraryBundleVerifier(
            environment: environment
        ).verify(bundleURL: bundleURL)
        let message = "Verified generated runtime library \(manifest.digest) at \(bundleURL.path)."
        return try success(
            command: "runtime-library-verify",
            message: message,
            json: MojoCommandJSONOutput(
                success: true,
                command: "runtime-library-verify",
                message: message,
                target: manifest.target.identity,
                module: manifest.moduleName,
                compilerVersion: manifest.compilerVersion,
                inputGraphDigest: manifest.inputGraphDigest,
                artifactDigest: manifest.digest,
                runtimeLibraries: manifest.runtimeLibraries.map {
                    URL(fileURLWithPath: $0.relativePath).lastPathComponent
                },
                bundlePath: bundleURL.path,
                library: manifest.library.relativePath
            ),
            format: format
        )
    }

    private func validateRuntimeReceiptDestination(
        _ receiptURL: URL,
        options: MojoRuntimeReceiptOptions
    ) throws {
        let destination = receiptURL.resolvingSymlinksInPath()
        let protectedInputs = [options.objectURL] + options.libraryURLs
        guard !protectedInputs.contains(where: {
            $0.resolvingSymlinksInPath() == destination
        }) else {
            throw MojoArtifactError.invalidArguments(
                "--receipt must not overwrite the object or a runtime library"
            )
        }
    }

    private func validateRuntimeBundleReceiptSource(
        _ receiptURL: URL,
        outputURL: URL
    ) throws {
        let output = outputURL.resolvingSymlinksInPath()
        let outputPrefix = output.path.hasSuffix("/")
            ? output.path
            : output.path + "/"
        let receipt = receiptURL.resolvingSymlinksInPath()
        guard receipt.path != output.path,
              !receipt.path.hasPrefix(outputPrefix) else {
            throw MojoArtifactError.invalidArguments(
                "The runtime bundle output must not contain its receipt input"
            )
        }
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

    private func resolvedPackageSources(
        options: ParsedOptions,
        layout: MojoPackageLayout
    ) throws -> [URL] {
        let sourceURLs = options.urls("--source")
        guard !sourceURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "MojoCommandPlugin must supply SwiftPM-resolved --source paths"
            )
        }
        guard let sourceRoot = options.value("--source-root") else {
            throw MojoArtifactError.invalidArguments(
                "MojoCommandPlugin must supply --source-root"
            )
        }
        try layout.validatePackageTarget()
        let resolvedRoot = URL(fileURLWithPath: sourceRoot)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedRoot == layout.packageRootURL else {
            throw MojoArtifactError.invalidArguments(
                "SwiftPM source root does not match the package root"
            )
        }
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        let normalizedSources = sourceURLs.map {
            $0.standardizedFileURL
        }.sorted { $0.path < $1.path }
        guard Set(normalizedSources.map(\.path)).count
                == normalizedSources.count else {
            throw MojoArtifactError.invalidArguments(
                "SwiftPM source inventory contains duplicate paths"
            )
        }
        guard normalizedSources.allSatisfy({ source in
            source.resolvingSymlinksInPath().standardizedFileURL.path
                .hasPrefix(rootPrefix)
                && source.pathExtension == "swift"
        }) else {
            throw MojoArtifactError.invalidArguments(
                "SwiftPM source inventory must contain only package-owned Swift files"
            )
        }
        return normalizedSources
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
      swift package --allow-writing-to-package-directory mojo init --target <target>
      swift package --disable-sandbox --allow-writing-to-package-directory mojo prepare --target <target>
      swift package --allow-writing-to-package-directory mojo inspect --target <target> [--format text|json]
      swift package --disable-sandbox --allow-writing-to-package-directory mojo doctor [--target <target>] [--format text|json]
      swift package --allow-writing-to-package-directory mojo release --target <target> [--format text|json]
      swift package --disable-sandbox --allow-writing-to-package-directory mojo runtime-prepare --object <object> --runtime-library <library> --receipt <receipt> --target-triple <triple> --target-cpu <cpu> [--target-accelerator <accelerator>] [--system-library <name>] [--format text|json]
      swift package --disable-sandbox mojo runtime-verify --object <object> --runtime-library <library> --receipt <receipt> --target-triple <triple> --target-cpu <cpu> [--target-accelerator <accelerator>] [--system-library <name>] [--format text|json]
      swift package --disable-sandbox --allow-writing-to-package-directory mojo runtime-bundle-prepare --object <object> --runtime-library <library> --receipt <receipt> --output <bundle> --executable-name <name> --target-triple <triple> --target-cpu <cpu> [--target-accelerator <accelerator>] [--system-library <name>] [--format text|json]
      swift package --disable-sandbox mojo runtime-bundle-verify --bundle <bundle> [--format text|json]
      swift package --disable-sandbox --allow-writing-to-package-directory mojo runtime-library-prepare --target <target> --runtime-library <library> --output <bundle> --target-triple <triple> --target-cpu <cpu> --target-accelerator <accelerator> [--system-library <name>] [--format text|json]
      swift package --disable-sandbox mojo runtime-library-verify --bundle <bundle> [--format text|json]
    The internal build plugin invokes the private swift-mojo verifier tool.
    """
}
