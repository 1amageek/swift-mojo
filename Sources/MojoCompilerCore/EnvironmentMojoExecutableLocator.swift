import Foundation

package struct EnvironmentMojoExecutableLocator: MojoExecutableLocating {
    private let environment: [String: String]

    package init(environment: [String: String]) {
        self.environment = environment
    }

    package func locate() throws -> String {
        let fileManager = FileManager.default

        if let explicitPath = environment["SWIFT_MOJO_EXECUTABLE"] {
            guard NSString(string: explicitPath).isAbsolutePath else {
                throw MojoCompilerToolError.executablePathMustBeAbsolute(
                    explicitPath
                )
            }
            guard fileManager.isExecutableFile(atPath: explicitPath) else {
                throw MojoCompilerToolError.executableNotFound
            }
            return explicitPath
        }

        if let searchPath = environment["PATH"] {
            for directory in searchPath.split(separator: ":") {
                let candidate = URL(
                    fileURLWithPath: String(directory),
                    isDirectory: true
                ).appendingPathComponent("mojo").path
                if fileManager.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }

        throw MojoCompilerToolError.executableNotFound
    }
}
