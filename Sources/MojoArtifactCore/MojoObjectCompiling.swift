import MojoCompilerCore

package protocol MojoObjectCompiling: Sendable {
    func compilerVersion() throws -> String

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String
}

extension MojoCompiler: MojoObjectCompiling {}
