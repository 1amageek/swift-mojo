import MojoBindingCore
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct MojoBodyMacro: BodyMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingBodyFor declaration: some DeclSyntaxProtocol & WithOptionalCodeBlockSyntax,
        in context: some MacroExpansionContext
    ) throws -> [CodeBlockItemSyntax] {
        guard let function = declaration.as(FunctionDeclSyntax.self) else {
            throw MojoMacroError.onlyFunctions
        }
        guard context.lexicalContext.isEmpty else {
            throw MojoBindingError.nonFileScopeUnsupported
        }
        let binding = try MojoBinding(function: function)
        var body: [CodeBlockItemSyntax] = []
        if binding.requiresCheckedAddition {
            body.append(
                """
                guard !\(raw: binding.lhsName).addingReportingOverflow(\(raw: binding.rhsName)).overflow else {
                    fatalError("Inline @mojo Int32 addition overflowed")
                }
                """
            )
        }
        body.append(
            """
            return __SwiftMojoGeneratedBindings.invokeInt32Binary(
                bindingID: UInt64(\(raw: String(binding.bindingID))),
                lhs: \(raw: binding.lhsName),
                rhs: \(raw: binding.rhsName)
            )
            """
        )
        return body
    }
}
