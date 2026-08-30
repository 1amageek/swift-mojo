import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct MojoStaticArtifactAttestationMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MojoMacroError.artifactOnlyFunctions
        }
        guard context.lexicalContext.isEmpty else {
            throw MojoMacroError.artifactFileScopeRequired
        }
        let signature = function.signature
        let returnType = signature.returnClause?.type.trimmedDescription
        let isThrowing = signature.effectSpecifiers?.throwsClause != nil
        let isAsync = signature.effectSpecifiers?.asyncSpecifier != nil
        guard signature.parameterClause.parameters.isEmpty,
              isThrowing,
              !isAsync,
              function.body == nil,
              returnType == "MojoStaticArtifactAttestation" else {
            throw MojoMacroError.invalidArtifactFunctionSignature
        }
        return [
            """
            return try __SwiftMojoGeneratedBindings.staticArtifactAttestation()
            """,
        ]
    }
}
