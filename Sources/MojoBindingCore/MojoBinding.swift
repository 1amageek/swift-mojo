import Foundation
import SwiftSyntax

package struct MojoBinding: Codable, Equatable, Sendable {
    package enum Operation: String, Codable, Equatable, Sendable {
        case addForward
        case addReversed

        package func mojoExpression(lhs: String, rhs: String) -> String {
            switch self {
            case .addForward:
                "\(lhs) + \(rhs)"
            case .addReversed:
                "\(rhs) + \(lhs)"
            }
        }
    }

    package static let schemaVersion = 1

    package let bindingID: UInt64
    package let functionName: String
    package let lhsName: String
    package let rhsName: String
    package let operation: Operation
    package let abiDigest: String
    package let implementationDigest: String

    package init(function: FunctionDeclSyntax) throws {
        guard !Self.containsConditionalCompilation(in: Syntax(function)) else {
            throw MojoBindingError.conditionalCompilationUnsupported
        }
        guard function.genericParameterClause == nil,
              function.genericWhereClause == nil else {
            throw MojoBindingError.genericUnsupported
        }
        guard function.signature.effectSpecifiers?.asyncSpecifier == nil else {
            throw MojoBindingError.asyncUnsupported
        }
        guard function.signature.effectSpecifiers?.throwsClause == nil else {
            throw MojoBindingError.throwingUnsupported
        }

        let functionName = function.name.text
        guard Self.isCIdentifier(functionName) else {
            throw MojoBindingError.unsupportedFunctionName(functionName)
        }

        let parameters = function.signature.parameterClause.parameters
        guard parameters.count == 2 else {
            throw MojoBindingError.invalidParameterCount
        }
        let lhs = parameters[parameters.startIndex]
        let rhs = parameters[parameters.index(after: parameters.startIndex)]
        guard let lhsName = Self.localName(of: lhs),
              let rhsName = Self.localName(of: rhs) else {
            throw MojoBindingError.missingLocalParameterName
        }
        guard Self.isInt32Parameter(lhs),
              Self.isInt32Parameter(rhs),
              function.signature.returnClause?.type.trimmedDescription == "Int32" else {
            throw MojoBindingError.unsupportedSignature
        }

        let operation = try Self.operation(
            function: function,
            lhsName: lhsName,
            rhsName: rhsName
        )
        let abiKey = "swift-mojo-binding-v1|\(functionName)|(Int32,Int32)->Int32"
        let implementationKey = "\(abiKey)|operation=\(operation.rawValue)"

        self.bindingID = MojoCanonicalDigest.identifier(abiKey)
        self.functionName = functionName
        self.lhsName = lhsName
        self.rhsName = rhsName
        self.operation = operation
        self.abiDigest = MojoCanonicalDigest.hex(abiKey)
        self.implementationDigest = MojoCanonicalDigest.hex(implementationKey)
    }

    package static func isInlineMojoFunction(
        _ function: FunctionDeclSyntax
    ) -> Bool {
        function.attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "mojo" else {
                return false
            }
            guard let arguments = attribute.arguments else {
                return true
            }
            if case .argumentList(let list) = arguments {
                return list.isEmpty
            }
            return false
        }
    }

    package var canonicalRecord: String {
        [
            String(Self.schemaVersion),
            String(bindingID),
            functionName,
            abiDigest,
            implementationDigest,
        ].joined(separator: "|")
    }

    package var mojoExpression: String {
        operation.mojoExpression(lhs: "lhs", rhs: "rhs")
    }

    private static func operation(
        function: FunctionDeclSyntax,
        lhsName: String,
        rhsName: String
    ) throws -> Operation {
        guard let body = function.body,
              body.statements.count == 1,
              let call = body.statements.first?.item.as(FunctionCallExprSyntax.self),
              call.calledExpression.trimmedDescription == "mojo",
              call.arguments.isEmpty,
              call.additionalTrailingClosures.isEmpty,
              let closure = call.trailingClosure,
              closure.statements.count == 1,
              let returnStatement = closure.statements.first?.item.as(ReturnStmtSyntax.self),
              let expression = returnStatement.expression?.trimmedDescription else {
            throw MojoBindingError.missingInlineBody
        }

        let compact = expression.filter { !$0.isWhitespace }
        if compact == "\(lhsName)+\(rhsName)" {
            return .addForward
        }
        if compact == "\(rhsName)+\(lhsName)" {
            return .addReversed
        }
        throw MojoBindingError.unsupportedExpression(expression)
    }

    private static func isInt32Parameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "Int32"
    }

    private static func localName(
        of parameter: FunctionParameterSyntax
    ) -> String? {
        let token = parameter.secondName ?? parameter.firstName
        return token.text == "_" ? nil : token.text
    }

    private static func isCIdentifier(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { codeUnit in
            codeUnit == 95
                || (codeUnit >= 48 && codeUnit <= 57)
                || (codeUnit >= 65 && codeUnit <= 90)
                || (codeUnit >= 97 && codeUnit <= 122)
        }
    }

    private static func containsConditionalCompilation(in syntax: Syntax) -> Bool {
        if syntax.is(IfConfigDeclSyntax.self) { return true }
        return syntax.children(viewMode: .sourceAccurate).contains { child in
            containsConditionalCompilation(in: child)
        }
    }
}
