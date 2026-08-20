package enum MojoBindingError: Error, Equatable, CustomStringConvertible {
    case asyncUnsupported
    case conditionalCompilationUnsupported
    case duplicateBindingID(UInt64)
    case externalBodyUnsupported
    case genericUnsupported
    case invalidExternalArguments
    case invalidParameterCount
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
            "Inline @mojo functions cannot be async in the P1 ABI"
        case .conditionalCompilationUnsupported:
            "Inline @mojo functions cannot be declared inside conditional compilation in the P1 source model"
        case .duplicateBindingID(let bindingID):
            "More than one @mojo function has binding ID \(bindingID)"
        case .externalBodyUnsupported:
            "External @mojo bindings declare package/function and do not contain a Swift body"
        case .genericUnsupported:
            "Inline @mojo functions cannot be generic in the P1 ABI"
        case .invalidExternalArguments:
            "@mojo accepts either no arguments or package/function string literals"
        case .invalidParameterCount:
            "Inline @mojo functions require exactly two parameters"
        case .invalidSourceFile(let path):
            "Swift binding source must be a regular non-symbolic file: '\(path)'"
        case .invalidSwiftSyntax(let file, let diagnosticCount):
            "Swift source '\(file)' contains \(diagnosticCount) parser diagnostic(s)"
        case .missingInlineBody:
            "Inline @mojo functions must contain exactly one return statement"
        case .missingLocalParameterName:
            "Every inline @mojo parameter requires a local name"
        case .noBindings:
            "No inline @mojo functions were found in the supplied Swift sources"
        case .nonFileScopeUnsupported:
            "@mojo currently supports only file-scope functions"
        case .throwingUnsupported:
            "Inline @mojo functions must be nonthrowing in the P1 ABI"
        case .unsupportedExpression(let expression):
            "The P1 Mojo DSL supports only addition of the two Int32 parameters; received '\(expression)'"
        case .unsupportedExternalFunctionName(let name):
            "External Mojo function name '\(name)' is not a portable identifier"
        case .unsupportedFunctionName(let name):
            "Inline @mojo function name '\(name)' is not a portable C identifier"
        case .unsupportedPackageName(let name):
            "Mojo package name '\(name)' is not a portable identifier"
        case .unsupportedSignature:
            "The P1 Mojo ABI supports only (Int32, Int32) -> Int32"
        }
    }
}
