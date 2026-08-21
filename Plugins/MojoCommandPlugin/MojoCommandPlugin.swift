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
            let sources = sourceTarget.sourceFiles(withSuffix: "swift")
                .map(\.url)
                .sorted { $0.path < $1.path }
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
        return command == "doctor" && arguments.contains("--target")
    }

    private static func requiresResolvedSwiftSources(command: String) -> Bool {
        ["prepare", "inspect", "release"].contains(command)
    }

    private static func requiresSourceTarget(
        command: String,
        arguments: [String]
    ) -> Bool {
        ["init", "prepare", "inspect", "release"].contains(command)
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
    case commandFailed(Int32)
    case duplicateOption(String)
    case missingOptionValue(String)
    case missingTarget
    case noSwiftSources(String)
    case reservedSourceInventoryOption
    case sourceTargetNotFound(String)

    var description: String {
        switch self {
        case .commandFailed(let status):
            "swift-mojo failed with exit status \(status)"
        case .duplicateOption(let option):
            "Option \(option) may be supplied only once"
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
