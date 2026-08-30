import Foundation
import MojoCompilerCore

package struct MojoStaticArchiveBuilder: Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func build(
        objectURL: URL,
        archiveURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        let adapter = try MojoNativeArtifactAdapter(target: target)
        let buildCommand = try command(
            adapter: adapter,
            arguments: ["rcs", archiveURL.path, objectURL.path]
        )
        _ = try execute(buildCommand)

        let listArguments: [String]
        switch adapter {
        case .appleXCFramework:
            listArguments = ["-t", archiveURL.path]
        case .linuxStaticLibraryBundle:
            listArguments = ["t", archiveURL.path]
        }
        let listCommand = try command(
            adapter: adapter,
            arguments: listArguments
        )
        let listing = try execute(listCommand)
        let expectedMember = objectURL.lastPathComponent
        let members = listing.output
            .split(whereSeparator: \Character.isNewline)
            .map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        guard members.contains(expectedMember) else {
            throw MojoArtifactError.staticArchiveMissingObject(
                target: target.identity,
                object: expectedMember
            )
        }
    }

    private func command(
        adapter: MojoNativeArtifactAdapter,
        arguments: [String]
    ) throws -> (executablePath: String, arguments: [String]) {
        switch adapter {
        case .appleXCFramework:
            return ("/usr/bin/ar", arguments)
        case .linuxStaticLibraryBundle:
            if let executablePath = environment["SWIFT_MOJO_LLVM_AR"] {
                guard NSString(string: executablePath).isAbsolutePath else {
                    throw MojoArtifactError.invalidArguments(
                        "SWIFT_MOJO_LLVM_AR must be an absolute path"
                    )
                }
                return (executablePath, arguments)
            }
#if os(macOS)
            return ("/usr/bin/xcrun", ["llvm-ar"] + arguments)
#else
            throw MojoArtifactError.invalidArguments(
                "SWIFT_MOJO_LLVM_AR must name an absolute LLVM archiver on non-macOS hosts"
            )
#endif
        }
    }

    private func execute(
        _ command: (executablePath: String, arguments: [String])
    ) throws -> MojoProcessResult {
        let result = try processRunner.capture(
            executablePath: command.executablePath,
            arguments: command.arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([command.executablePath] + command.arguments)
                    .joined(separator: " "),
                status: result.status,
                diagnostic: result.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
        return result
    }
}
