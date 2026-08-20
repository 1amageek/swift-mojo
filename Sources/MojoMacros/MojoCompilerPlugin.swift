import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MojoCompilerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MojoBodyMacro.self,
    ]
}
