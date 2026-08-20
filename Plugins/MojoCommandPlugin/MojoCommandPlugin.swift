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
        let process = Process()
        process.executableURL = tool.url
        process.arguments = forwarded
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
}

private enum CommandPluginError: Error, CustomStringConvertible {
    case commandFailed(Int32)

    var description: String {
        switch self {
        case .commandFailed(let status):
            "swift-mojo failed with exit status \(status)"
        }
    }
}
