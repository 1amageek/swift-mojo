import MojoRuntimeProtocolCore
import SwiftSyntax

/// Parses literal resource types; no consumer expression is evaluated during generation.
package enum MojoResourceBindingAttribute {
    package static let labels: Set<String> = [
        "argumentTypes", "inputTypes", "inputRanks", "resultTypes", "outputTypes",
    ]

    package static func signature(of function: FunctionDeclSyntax) throws -> MojoRuntimeResourceSignature? {
        guard let attribute = function.attributes.compactMap({ $0.as(AttributeSyntax.self) })
            .first(where: { $0.attributeName.trimmedDescription == "mojo" }),
              case .argumentList(let list) = attribute.arguments else { return nil }
        var fields: [String: ExprSyntax] = [:]
        for argument in list {
            guard let label = argument.label?.text, labels.contains(label) else { continue }
            guard fields.updateValue(argument.expression, forKey: label) == nil else {
                throw MojoBindingError.invalidResourceArguments
            }
        }
        guard !fields.isEmpty else { return nil }
        guard Set(fields.keys) == labels else { throw MojoBindingError.invalidResourceArguments }
        func elements(_ name: String) throws -> ArrayElementListSyntax {
            guard let array = fields[name]?.as(ArrayExprSyntax.self),
                  array.elements.count <= Int(UInt16.max) else {
                throw MojoBindingError.invalidResourceArguments
            }
            return array.elements
        }
        func types(_ name: String) throws -> [MojoRuntimeElementType] {
            try elements(name).map { item in
                guard let member = item.expression.as(MemberAccessExprSyntax.self),
                      member.base == nil,
                      let type = MojoRuntimeElementType.allCases.first(where: {
                          $0.sourceName == member.declName.baseName.text
                      }) else { throw MojoBindingError.invalidResourceArguments }
                return type
            }
        }
        let inputTypes = try types("inputTypes")
        let ranks: [UInt16] = try elements("inputRanks").map { item in
            guard let integer = item.expression.as(IntegerLiteralExprSyntax.self),
                  let rank = UInt16(integer.literal.text) else {
                throw MojoBindingError.invalidResourceArguments
            }
            return rank
        }
        guard ranks.count == inputTypes.count else { throw MojoBindingError.invalidResourceArguments }
        return try MojoRuntimeResourceSignature(
            arguments: types("argumentTypes"),
            inputs: zip(inputTypes, ranks).map { .init(element: $0, rank: $1) },
            results: types("resultTypes"), outputs: types("outputTypes")
        )
    }
}
