import Foundation

package struct MojoCompiler {
    private let executablePath: String
    private let processRunner: any MojoProcessRunning

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try self.init(
            executableLocator: EnvironmentMojoExecutableLocator(
                environment: environment
            ),
            processRunner: FoundationMojoProcessRunner(environment: environment)
        )
    }

    package init(
        executableLocator: any MojoExecutableLocating,
        processRunner: any MojoProcessRunning
    ) throws {
        executablePath = try executableLocator.locate()
        self.processRunner = processRunner
    }

    package func compilerVersion() throws -> String {
        let result = try execute(arguments: ["--version"])
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    package func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration
    ) throws -> String {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputPath) {
            try fileManager.removeItem(atPath: outputPath)
        }
        let arguments = [
            "build",
            "--emit", "object",
        ] + target.compilerArguments + [
            "-o", outputPath,
            inputPath,
        ]
        let result = try execute(arguments: arguments)
        guard fileManager.fileExists(atPath: outputPath) else {
            throw MojoCompilerToolError.artifactNotProduced(outputPath)
        }
        return result.output
    }

    package func execute(arguments: [String]) throws -> MojoProcessResult {
        let result = try processRunner.capture(
            executablePath: executablePath,
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoCompilerToolError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: result.status,
                diagnostic: result.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return result
    }
}
