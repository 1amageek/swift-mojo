import Foundation
import MojoCompilerCore

package protocol MojoRuntimeWorkerCCompiling: Sendable {
    func compile(
        sourceURL: URL,
        includeDirectoryURL: URL,
        outputURL: URL,
        target: MojoTargetConfiguration
    ) throws
}

package struct MojoRuntimeWorkerCCompiler: MojoRuntimeWorkerCCompiling, Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func compile(
        sourceURL: URL,
        includeDirectoryURL: URL,
        outputURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        let source = try validatedRegularFile(
            sourceURL,
            description: "Runtime worker C source"
        )
        let includeDirectory = try validatedDirectory(
            includeDirectoryURL,
            description: "Runtime worker C header directory"
        )
        let output = outputURL.standardizedFileURL
        guard NSString(string: output.path).isAbsolutePath,
              !output.lastPathComponent.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "Runtime worker C object output must be an absolute file path"
            )
        }
        let outputDirectory = try validatedDirectory(
            output.deletingLastPathComponent(),
            description: "Runtime worker C object output directory"
        )
        let canonicalOutput = outputDirectory.appendingPathComponent(
            output.lastPathComponent,
            isDirectory: false
        )
        guard canonicalOutput.path != source.path else {
            throw MojoArtifactError.invalidArguments(
                "Runtime worker C source and object output must be different files"
            )
        }
        try validateExistingOutput(canonicalOutput)

        let tool = try clang(target: target)
        let arguments = tool.prefixArguments + [
            "-target", target.triple,
            "-mcpu=\(target.cpu)",
            "-std=c11",
            "-Werror",
            "-I", includeDirectory.path,
            "-c", source.path,
            "-o", canonicalOutput.path,
        ]
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
        guard FileManager.default.fileExists(atPath: canonicalOutput.path) else {
            throw MojoCompilerToolError.artifactNotProduced(
                canonicalOutput.path
            )
        }
        try MojoRegularFile.validate(at: canonicalOutput)
    }

    private func validatedRegularFile(
        _ url: URL,
        description: String
    ) throws -> URL {
        let standardized = url.standardizedFileURL
        guard NSString(string: standardized.path).isAbsolutePath else {
            throw MojoArtifactError.invalidArguments(
                "\(description) must be an absolute path"
            )
        }
        do {
            try MojoRegularFile.validate(at: standardized)
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw MojoArtifactError.invalidArguments(
                "\(description) must be an existing regular file at '\(standardized.path)'"
            )
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
    }

    private func validatedDirectory(
        _ url: URL,
        description: String
    ) throws -> URL {
        let standardized = url.standardizedFileURL
        guard NSString(string: standardized.path).isAbsolutePath else {
            throw MojoArtifactError.invalidArguments(
                "\(description) must be an absolute path"
            )
        }
        let values: URLResourceValues
        do {
            values = try standardized.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw MojoArtifactError.invalidArguments(
                "\(description) must be an existing non-symbolic-link directory at '\(standardized.path)'"
            )
        }
        guard values.isSymbolicLink != true else {
            throw MojoArtifactError.symbolicLinkUnsupported(
                standardized.path
            )
        }
        guard values.isDirectory == true else {
            throw MojoArtifactError.invalidArguments(
                "\(description) must be an existing non-symbolic-link directory at '\(standardized.path)'"
            )
        }
        return standardized.resolvingSymlinksInPath().standardizedFileURL
    }

    private func validateExistingOutput(_ outputURL: URL) throws {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            return
        }
        try MojoRegularFile.validate(at: outputURL)
    }

    private func clang(
        target: MojoTargetConfiguration
    ) throws -> (executablePath: String, prefixArguments: [String]) {
        _ = try MojoNativeArtifactAdapter(target: target)
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
