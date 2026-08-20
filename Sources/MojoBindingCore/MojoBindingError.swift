package enum MojoBindingError: Error, Equatable, CustomStringConvertible {
    case asyncUnsupported
    case conditionalCompilationUnsupported
    case duplicateBindingID(UInt64)
    case genericUnsupported
    case invalidParameterCount
    case missingInlineBody
    case missingLocalParameterName
    case noBindings
    case throwingUnsupported
    case unsupportedExpression(String)
    case unsupportedFunctionName(String)
    case unsupportedSignature

    package var description: String {
        switch self {
        case .asyncUnsupported:
            "Inline @mojo functions cannot be async in the P1 ABI"
        case .conditionalCompilationUnsupported:
            "Inline @mojo functions cannot be declared inside conditional compilation in the P1 source model"
        case .duplicateBindingID(let bindingID):
            "More than one @mojo function has binding ID \(bindingID)"
        case .genericUnsupported:
            "Inline @mojo functions cannot be generic in the P1 ABI"
        case .invalidParameterCount:
            "Inline @mojo functions require exactly two parameters"
        case .missingInlineBody:
            "The function body must contain exactly one mojo { ... } block"
        case .missingLocalParameterName:
            "Every inline @mojo parameter requires a local name"
        case .noBindings:
            "No inline @mojo functions were found in the supplied Swift sources"
        case .throwingUnsupported:
            "Inline @mojo functions must be nonthrowing in the P1 ABI"
        case .unsupportedExpression(let expression):
            "The P1 Mojo DSL supports only addition of the two Int32 parameters; received '\(expression)'"
        case .unsupportedFunctionName(let name):
            "Inline @mojo function name '\(name)' is not a portable C identifier"
        case .unsupportedSignature:
            "The P1 Mojo ABI supports only (Int32, Int32) -> Int32"
        }
    }
}
