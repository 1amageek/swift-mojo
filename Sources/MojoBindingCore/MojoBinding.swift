import Foundation
import SwiftSyntax

package struct MojoBinding: Codable, Equatable, Sendable {
    package enum Signature: String, Codable, Equatable, Hashable, Sendable {
        case int32Binary
        case borrowedFloat32Buffer

        package var canonicalRecord: String {
            switch self {
            case .int32Binary:
                // This spelling is part of the proven scalar binding identity.
                "(Int32,Int32)->Int32"
            case .borrowedFloat32Buffer:
                "([Float])->throws Float"
            }
        }
    }

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

    package enum Implementation: Codable, Equatable, Sendable {
        case inline(Operation)
        case external(package: String, function: String)

        package var canonicalRecord: String {
            switch self {
            case .inline(let operation):
                "inline:\(operation.rawValue)"
            case .external(let package, let function):
                "external:\(package).\(function)"
            }
        }
    }

    package static let schemaVersion = 1

    package let bindingID: UInt64
    package let functionName: String
    package let signature: Signature
    package let parameterNames: [String]
    package let implementation: Implementation
    package let abiDigest: String
    package let implementationDigest: String
    package let sourceReference: MojoSourceReference?

    package init(
        function: FunctionDeclSyntax,
        sourceReference: MojoSourceReference? = nil
    ) throws {
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

        let functionName = function.name.text
        guard Self.isCIdentifier(functionName) else {
            throw MojoBindingError.unsupportedFunctionName(functionName)
        }

        let signature = try Self.signature(function: function)
        let parameterNames = try function.signature.parameterClause.parameters
            .map { parameter in
                guard let name = Self.localName(of: parameter) else {
                    throw MojoBindingError.missingLocalParameterName
                }
                return name
            }

        let implementation = try Self.implementation(
            function: function,
            signature: signature,
            parameterNames: parameterNames
        )
        let abiKey = [
            "swift-mojo-binding-v1",
            functionName,
            signature.canonicalRecord,
        ].joined(separator: "|")
        let implementationKey: String
        switch implementation {
        case .inline(let operation):
            implementationKey = "\(abiKey)|operation=\(operation.rawValue)"
        case .external:
            implementationKey = "\(abiKey)|\(implementation.canonicalRecord)"
        }

        self.bindingID = MojoCanonicalDigest.identifier(abiKey)
        self.functionName = functionName
        self.signature = signature
        self.parameterNames = parameterNames
        self.implementation = implementation
        self.abiDigest = MojoCanonicalDigest.hex(abiKey)
        self.implementationDigest = MojoCanonicalDigest.hex(implementationKey)
        self.sourceReference = sourceReference
    }

    package static func isMojoFunction(
        _ function: FunctionDeclSyntax
    ) -> Bool {
        function.attributes.contains { element in
            guard let attribute = element.as(AttributeSyntax.self),
                  attribute.attributeName.trimmedDescription == "mojo" else {
                return false
            }
            return true
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

    package var requiresCheckedAddition: Bool {
        if case .inline = implementation {
            return true
        }
        return false
    }

    package var lhsName: String {
        precondition(signature == .int32Binary)
        return parameterNames[0]
    }

    package var rhsName: String {
        precondition(signature == .int32Binary)
        return parameterNames[1]
    }

    package var bufferName: String {
        precondition(signature == .borrowedFloat32Buffer)
        return parameterNames[0]
    }

    private static func implementation(
        function: FunctionDeclSyntax,
        signature: Signature,
        parameterNames: [String]
    ) throws -> Implementation {
        let arguments = try mojoArguments(function: function)
        if !arguments.isEmpty {
            guard arguments.count == 2,
                  let package = arguments["package"],
                  let externalFunction = arguments["function"] else {
                throw MojoBindingError.invalidExternalArguments
            }
            guard MojoPortableIdentifier.isValid(package) else {
                throw MojoBindingError.unsupportedPackageName(package)
            }
            guard MojoPortableIdentifier.isValid(externalFunction) else {
                throw MojoBindingError.unsupportedExternalFunctionName(
                    externalFunction
                )
            }
            guard function.body == nil || function.body?.statements.isEmpty == true else {
                throw MojoBindingError.externalBodyUnsupported
            }
            return .external(
                package: package,
                function: externalFunction
            )
        }

        guard signature == .int32Binary else {
            throw MojoBindingError.bufferRequiresExternalImplementation
        }

        let expression = try inlineExpression(function: function)
        let lhsName = parameterNames[0]
        let rhsName = parameterNames[1]

        let compact = expression.filter { !$0.isWhitespace }
        if compact == "\(lhsName)+\(rhsName)" {
            return .inline(.addForward)
        }
        if compact == "\(rhsName)+\(lhsName)" {
            return .inline(.addReversed)
        }
        throw MojoBindingError.unsupportedExpression(expression)
    }

    private static func inlineExpression(
        function: FunctionDeclSyntax
    ) throws -> String {
        guard let body = function.body,
              body.statements.count == 1 else {
            throw MojoBindingError.missingInlineBody
        }
        if let returnStatement = body.statements.first?.item.as(
            ReturnStmtSyntax.self
        ), let expression = returnStatement.expression?.trimmedDescription {
            return expression
        }
        throw MojoBindingError.missingInlineBody
    }

    private static func mojoArguments(
        function: FunctionDeclSyntax
    ) throws -> [String: String] {
        guard let attribute = function.attributes.compactMap({ element in
            element.as(AttributeSyntax.self)
        }).first(where: {
            $0.attributeName.trimmedDescription == "mojo"
        }), let arguments = attribute.arguments else {
            return [:]
        }
        guard case .argumentList(let list) = arguments else {
            throw MojoBindingError.invalidExternalArguments
        }

        var values: [String: String] = [:]
        for argument in list {
            guard let label = argument.label?.text,
                  let literal = argument.expression.as(
                    StringLiteralExprSyntax.self
                  ),
                  literal.segments.count == 1,
                  let segment = literal.segments.first?.as(
                    StringSegmentSyntax.self
                  ),
                  values.updateValue(segment.content.text, forKey: label) == nil else {
                throw MojoBindingError.invalidExternalArguments
            }
        }
        return values
    }

    private static func isInt32Parameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "Int32"
    }

    private static func signature(
        function: FunctionDeclSyntax
    ) throws -> Signature {
        let parameters = function.signature.parameterClause.parameters
        let returnType = function.signature.returnClause?.type
            .trimmedDescription
        let throwsClause = function.signature.effectSpecifiers?.throwsClause
        let isUntypedThrowing = throwsClause?.trimmedDescription == "throws"

        if parameters.count == 2 {
            let lhs = parameters[parameters.startIndex]
            let rhs = parameters[parameters.index(after: parameters.startIndex)]
            guard Self.isInt32Parameter(lhs),
                  Self.isInt32Parameter(rhs),
                  returnType == "Int32" else {
                throw MojoBindingError.unsupportedSignature
            }
            guard throwsClause == nil else {
                throw MojoBindingError.throwingUnsupported
            }
            return .int32Binary
        }

        if parameters.count == 1,
           let parameter = parameters.first,
           parameter.ellipsis == nil,
           parameter.defaultValue == nil,
           parameter.type.trimmedDescription == "[Float]",
           returnType == "Float",
           isUntypedThrowing {
            return .borrowedFloat32Buffer
        }

        throw MojoBindingError.unsupportedSignature
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
