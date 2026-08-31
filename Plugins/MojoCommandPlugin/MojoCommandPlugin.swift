import Foundation
import PackagePlugin

@main
struct MojoCommandPlugin: CommandPlugin {
    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        let tool = try context.tool(named: "swift-mojo")
        var forwarded = arguments
        let explicitBindingSourcePaths = try Self.removeOptionValues(
            "--binding-source",
            from: &forwarded
        )
        if !explicitBindingSourcePaths.isEmpty {
            guard forwarded.first == "runtime-worker-prepare" else {
                throw CommandPluginError.bindingSourceNotAllowed(
                    forwarded.first ?? "<missing>"
                )
            }
            guard forwarded.contains("--target") else {
                throw CommandPluginError.missingTarget
            }
        }
        if let command = forwarded.first,
           Self.requiresPackageRoot(
            command: command,
            arguments: forwarded
           ),
           !forwarded.contains("--package-root") {
            forwarded.insert(
                contentsOf: [
                    "--package-root",
                    context.package.directoryURL.path,
                ],
                at: 1
            )
        }
        if let command = forwarded.first,
           Self.requiresSourceTarget(
            command: command,
            arguments: forwarded
           ) {
            guard let targetName = try Self.optionValue(
                "--target",
                in: forwarded
            ) else {
                throw CommandPluginError.missingTarget
            }
            guard let sourceTarget = context.package.targets.first(
                where: { $0.name == targetName }
            )?.sourceModule else {
                throw CommandPluginError.sourceTargetNotFound(targetName)
            }
            let resolvedSources = sourceTarget.sourceFiles
                .filter {
                    $0.type == .source && $0.url.pathExtension == "swift"
                }
                .map(\.url)
                .sorted { $0.path < $1.path }
            let explicitSources = try Self.validatedBindingSources(
                explicitBindingSourcePaths,
                packageRootURL: context.package.directoryURL,
                targetDirectoryURL: sourceTarget.directoryURL
            )
            let sources = explicitSources.isEmpty
                ? resolvedSources
                : explicitSources
            guard !sources.isEmpty else {
                throw CommandPluginError.noSwiftSources(targetName)
            }
            if Self.requiresResolvedSwiftSources(command: command) {
                let reservedOptions = ["--source", "--source-root"]
                guard !reservedOptions.contains(
                    where: { forwarded.contains($0) }
                ) else {
                    throw CommandPluginError.reservedSourceInventoryOption
                }
                forwarded.append(
                    contentsOf: [
                        "--source-root",
                        context.package.directoryURL.path,
                    ]
                )
                for source in sources {
                    forwarded.append(contentsOf: ["--source", source.path])
                }
            }
        }
        try Self.run(toolURL: tool.url, arguments: forwarded)
    }

    private static func removeOptionValues(
        _ option: String,
        from arguments: inout [String]
    ) throws -> [String] {
        var retained: [String] = []
        retained.reserveCapacity(arguments.count)
        var values: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            guard arguments[index] == option else {
                retained.append(arguments[index])
                index = arguments.index(after: index)
                continue
            }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex,
                  !arguments[valueIndex].hasPrefix("--") else {
                throw CommandPluginError.missingOptionValue(option)
            }
            values.append(arguments[valueIndex])
            index = arguments.index(after: valueIndex)
        }
        arguments = retained
        return values
    }

    private static func validatedBindingSources(
        _ paths: [String],
        packageRootURL: URL,
        targetDirectoryURL: URL
    ) throws -> [URL] {
        let lexicalTargetDirectory = targetDirectoryURL.standardizedFileURL
        let resolvedTargetDirectory = targetDirectoryURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var sources: [URL] = []
        sources.reserveCapacity(paths.count)
        var canonicalPaths: Set<String> = []
        for path in paths {
            guard !path.isEmpty else {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "the path is empty"
                )
            }
            let candidate = (path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : packageRootURL.appendingPathComponent(path))
                .standardizedFileURL
            guard candidate.pathExtension == "swift" else {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "the file extension is not .swift"
                )
            }
            guard let relativePath = relativePath(
                of: candidate,
                within: lexicalTargetDirectory
            ) else {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "the file is outside the selected target directory"
                )
            }
            let resolvedCandidate = candidate.resolvingSymlinksInPath()
                .standardizedFileURL
            let expectedResolvedCandidate = resolvedTargetDirectory
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard resolvedCandidate == expectedResolvedCandidate else {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "a path component is a symbolic link"
                )
            }
            let resourceValues: URLResourceValues
            do {
                resourceValues = try candidate.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "the file cannot be inspected"
                )
            }
            guard resourceValues.isSymbolicLink != true,
                  resourceValues.isRegularFile == true else {
                throw CommandPluginError.invalidBindingSource(
                    path: path,
                    reason: "the path is not a regular non-symlink file"
                )
            }
            guard canonicalPaths.insert(resolvedCandidate.path).inserted else {
                throw CommandPluginError.duplicateBindingSource(
                    resolvedCandidate.path
                )
            }
            sources.append(resolvedCandidate)
        }
        return sources.sorted { $0.path < $1.path }
    }

    private static func relativePath(
        of child: URL,
        within directory: URL
    ) -> String? {
        let prefix = directory.path.hasSuffix("/")
            ? directory.path
            : directory.path + "/"
        guard child.path.hasPrefix(prefix) else { return nil }
        let relativePath = String(child.path.dropFirst(prefix.count))
        return relativePath.isEmpty ? nil : relativePath
    }

    private static func run(
        toolURL: URL,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = toolURL
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw CommandPluginError.commandFailed(process.terminationStatus)
        }
    }

    private static func requiresPackageRoot(
        command: String,
        arguments: [String]
    ) -> Bool {
        if ["init", "prepare", "inspect", "release"].contains(command) {
            return true
        }
        if command == "runtime-library-prepare"
            || command == "runtime-worker-prepare" {
            return arguments.contains("--target")
        }
        return command == "doctor" && arguments.contains("--target")
    }

    private static func requiresResolvedSwiftSources(command: String) -> Bool {
        [
            "prepare", "inspect", "release", "runtime-library-prepare",
            "runtime-worker-prepare",
        ]
            .contains(command)
    }

    private static func requiresSourceTarget(
        command: String,
        arguments: [String]
    ) -> Bool {
        ["init", "prepare", "inspect", "release"].contains(command)
            || (command == "runtime-library-prepare"
                && arguments.contains("--target"))
            || (command == "runtime-worker-prepare"
                && arguments.contains("--target"))
            || (command == "doctor" && arguments.contains("--target"))
    }

    private static func optionValue(
        _ option: String,
        in arguments: [String]
    ) throws -> String? {
        let indices = arguments.indices.filter { arguments[$0] == option }
        guard indices.count <= 1 else {
            throw CommandPluginError.duplicateOption(option)
        }
        guard let index = indices.first else {
            return nil
        }
        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex,
              !arguments[valueIndex].hasPrefix("--") else {
            throw CommandPluginError.missingOptionValue(option)
        }
        return arguments[valueIndex]
    }
}

private enum CommandPluginError: Error, CustomStringConvertible {
    case bindingSourceNotAllowed(String)
    case commandFailed(Int32)
    case duplicateOption(String)
    case duplicateBindingSource(String)
    case invalidBindingSource(path: String, reason: String)
    case missingOptionValue(String)
    case missingTarget
    case noSwiftSources(String)
    case reservedSourceInventoryOption
    case sourceTargetNotFound(String)

    var description: String {
        switch self {
        case .bindingSourceNotAllowed(let command):
            "--binding-source is not supported by command '\(command)'"
        case .commandFailed(let status):
            "swift-mojo failed with exit status \(status)"
        case .duplicateOption(let option):
            "Option \(option) may be supplied only once"
        case .duplicateBindingSource(let path):
            "Binding source inventory contains duplicate path '\(path)'"
        case .invalidBindingSource(let path, let reason):
            "Invalid binding source '\(path)': \(reason)"
        case .missingOptionValue(let option):
            "Missing value for \(option)"
        case .missingTarget:
            "--target is required"
        case .noSwiftSources(let target):
            "SwiftPM resolved no Swift sources for target '\(target)'"
        case .reservedSourceInventoryOption:
            "--source and --source-root are owned by MojoCommandPlugin"
        case .sourceTargetNotFound(let target):
            "SwiftPM source target '\(target)' was not found"
        }
    }
}
