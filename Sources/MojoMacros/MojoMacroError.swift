enum MojoMacroError: Error, CustomStringConvertible {
    case onlyFunctions
    case argumentsUnsupported

    var description: String {
        switch self {
        case .onlyFunctions:
            "@mojo can only be attached to a function"
        case .argumentsUnsupported:
            "@mojo does not accept arguments; write Mojo code in the function's mojo block"
        }
    }
}
