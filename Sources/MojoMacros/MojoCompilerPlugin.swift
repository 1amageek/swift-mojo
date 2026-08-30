import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct MojoCompilerPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        MojoStaticArtifactAttestationMacro.self,
        MojoBodyMacro.self,
    ]
}
