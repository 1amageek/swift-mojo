package enum MojoBindingError: Error, Equatable, CustomStringConvertible {
    case asyncUnsupported
    case bufferRequiresExternalImplementation
    case conditionalCompilationUnsupported
    case duplicateBindingID(UInt64)
    case externalBodyUnsupported
    case genericUnsupported
    case invalidExternalArguments
    case invalidSourceFile(String)
    case invalidSwiftSyntax(file: String, diagnosticCount: Int)
    case missingInlineBody
    case missingLocalParameterName
    case noBindings
    case nonFileScopeUnsupported
    case throwingUnsupported
    case unsupportedExpression(String)
    case unsupportedExternalFunctionName(String)
    case unsupportedFunctionName(String)
    case unsupportedPackageName(String)
    case unsupportedSignature

    package var description: String {
        switch self {
        case .asyncUnsupported:
            "@mojo functions cannot be async in the current ABI"
        case .bufferRequiresExternalImplementation:
            "Borrowed Float buffer bindings require an external Mojo package implementation"
        case .conditionalCompilationUnsupported:
            "@mojo functions cannot be declared inside conditional compilation in the current source model"
        case .duplicateBindingID(let bindingID):
            "More than one @mojo function has binding ID \(bindingID)"
        case .externalBodyUnsupported:
            "External @mojo bindings declare package/function and do not contain a Swift body"
        case .genericUnsupported:
            "@mojo functions cannot be generic in the current ABI"
        case .invalidExternalArguments:
            "@mojo accepts either no arguments or package/function string literals"
        case .invalidSourceFile(let path):
            "Swift binding source must be a regular non-symbolic file: '\(path)'"
        case .invalidSwiftSyntax(let file, let diagnosticCount):
            "Swift source '\(file)' contains \(diagnosticCount) parser diagnostic(s)"
        case .missingInlineBody:
            "Inline @mojo functions must contain exactly one return statement"
        case .missingLocalParameterName:
            "Every @mojo parameter requires a local name"
        case .noBindings:
            "No @mojo functions were found in the supplied Swift sources"
        case .nonFileScopeUnsupported:
            "@mojo currently supports only file-scope functions"
        case .throwingUnsupported:
            "Int32 binary @mojo functions must be nonthrowing"
        case .unsupportedExpression(let expression):
            "The P1 Mojo DSL supports only addition of the two Int32 parameters; received '\(expression)'"
        case .unsupportedExternalFunctionName(let name):
            "External Mojo function name '\(name)' is not a portable identifier"
        case .unsupportedFunctionName(let name):
            "@mojo function name '\(name)' is not a portable C identifier"
        case .unsupportedPackageName(let name):
            "Mojo package name '\(name)' is not a portable identifier"
        case .unsupportedSignature:
            "The Mojo ABI supports (Int32, Int32) -> Int32 and ([Float]) throws -> Float"
        }
    }
}
