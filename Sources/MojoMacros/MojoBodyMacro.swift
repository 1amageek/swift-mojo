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
        switch binding.signature {
        case .int32Binary:
            body.append(
                """
                return __SwiftMojoGeneratedBindings.invokeInt32Binary(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    lhs: \(raw: binding.lhsName),
                    rhs: \(raw: binding.rhsName)
                )
                """
            )
        case .borrowedFloat32Buffer:
            body.append(
                """
                return try __SwiftMojoGeneratedBindings.invokeFloatBuffer(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    values: \(raw: binding.bufferName)
                )
                """
            )
        case .borrowedMutableFloat32Buffers:
            body.append(
                """
                try __SwiftMojoGeneratedBindings.invokeFloatBufferMutation(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    input: \(raw: binding.inputBufferName),
                    output: &\(raw: binding.outputBufferName)
                )
                """
            )
        case .borrowedMutableFloat64Buffers:
            body.append(
                """
                try __SwiftMojoGeneratedBindings.invokeDoubleBufferMutation(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    input: \(raw: binding.doubleInputBufferName),
                    output: &\(raw: binding.doubleOutputBufferName)
                )
                """
            )
        case .runtimeSessionFactory:
            body.append(
                """
                return try __SwiftMojoGeneratedBindings.makeSession(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    requirements: \(raw: binding.requirementsName)
                )
                """
            )
        case .sessionFloat32BufferFactory:
            body.append(
                """
                return try __SwiftMojoGeneratedBindings.makeFloat32Buffer(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    session: \(raw: binding.resourceSessionName),
                    elementCount: \(raw: binding.resourceElementCountName),
                    memoryKind: \(raw: binding.resourceMemoryKindName)
                )
                """
            )
        case .sessionBorrowedMutableFloat32Buffers:
            body.append(
                """
                try __SwiftMojoGeneratedBindings.invokeSessionFloatBufferMutation(
                    bindingID: UInt64(\(raw: String(binding.bindingID))),
                    session: \(raw: binding.sessionName),
                    input: \(raw: binding.sessionInputBufferName),
                    output: &\(raw: binding.sessionOutputBufferName)
                )
                """
            )
        }
        return body
    }
}
