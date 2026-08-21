import Foundation
import MojoCompilerCore

package struct MojoRuntimeExecutableLinker: MojoRuntimeExecutableLinking, Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func link(
        objectURL: URL,
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String]
    ) throws {
        let tool = try clang(target: target)
        var arguments = tool.prefixArguments + [
            "-target", target.triple, objectURL.path,
        ]
        arguments.append(contentsOf: libraryURLs.map(\.path))
        if target.triple.lowercased().contains("-linux-") {
            let explicitSystemLibraries = systemDependencies.filter {
                !MojoRuntimeReceiptPreparer.isDefaultSystemDependency(
                    $0,
                    target: target
                )
            }
            arguments.append(
                contentsOf: explicitSystemLibraries.sorted().map {
                    "-Wl,-l:\($0)"
                }
            )
            arguments.append(contentsOf: [
                "-Wl,-rpath,$ORIGIN/../lib",
                "-Wl,--enable-new-dtags",
            ])
        } else if target.triple.lowercased().contains("-apple-") {
            arguments.append("-Wl,-rpath,@executable_path/../lib")
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        arguments.append(contentsOf: ["-o", outputURL.path])
        let result = try processRunner.capture(
            executablePath: tool.executablePath,
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([tool.executablePath] + arguments).joined(
                    separator: " "
                ),
                status: result.status,
                diagnostic: result.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    private func clang(
        target: MojoTargetConfiguration
    ) throws -> (executablePath: String, prefixArguments: [String]) {
        if let path = environment["SWIFT_MOJO_CLANG"] {
            guard NSString(string: path).isAbsolutePath else {
                throw MojoArtifactError.invalidArguments(
                    "SWIFT_MOJO_CLANG must be an absolute path"
                )
            }
            return (path, [])
        }
#if os(macOS)
        if target.triple.lowercased().contains("-apple-") {
            return ("/usr/bin/xcrun", ["clang"])
        }
#endif
        return ("/usr/bin/clang", [])
    }
}
