enum MojoMacroError: Error, CustomStringConvertible {
    case onlyFunctions

    var description: String {
        switch self {
        case .onlyFunctions:
            "@mojo can only be attached to a function"
        }
    }
}
