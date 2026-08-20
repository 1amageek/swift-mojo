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
        guard Self.isArgumentFree(attribute: node) else {
            throw MojoMacroError.argumentsUnsupported
        }
        let binding = try MojoBinding(function: function)
        return [
            """
            guard !\(raw: binding.lhsName).addingReportingOverflow(\(raw: binding.rhsName)).overflow else {
                fatalError("Inline @mojo Int32 addition overflowed")
            }
            """,
            """
            return __SwiftMojoGeneratedBindings.invokeInt32Binary(
                bindingID: UInt64(\(raw: String(binding.bindingID))),
                lhs: \(raw: binding.lhsName),
                rhs: \(raw: binding.rhsName)
            )
            """
        ]
    }

    private static func isArgumentFree(attribute: AttributeSyntax) -> Bool {
        guard let arguments = attribute.arguments else {
            return true
        }
        if case .argumentList(let list) = arguments {
            return list.isEmpty
        }
        return false
    }
}
