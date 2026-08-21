import Foundation
import SwiftSyntax

package struct MojoBinding: Codable, Equatable, Sendable {
    package enum Signature: String, Codable, Equatable, Hashable, Sendable {
        case int32Binary
        case borrowedFloat32Buffer
        case borrowedMutableFloat32Buffers
        case borrowedMutableFloat64Buffers
        case runtimeSessionFactory
        case sessionFloat32BufferFactory
        case sessionBorrowedMutableFloat32Buffers

        package var canonicalRecord: String {
            switch self {
            case .int32Binary:
                // This spelling is part of the proven scalar binding identity.
                "(Int32,Int32)->Int32"
            case .borrowedFloat32Buffer:
                "([Float])->throws Float"
            case .borrowedMutableFloat32Buffers:
                "([Float],inout [Float])->throws Void"
            case .borrowedMutableFloat64Buffers:
                "([Double],inout [Double])->throws Void"
            case .runtimeSessionFactory:
                "(MojoSessionRequirements)->throws MojoSessionOwner"
            case .sessionFloat32BufferFactory:
                "(MojoSessionOwner,UInt64,MojoBufferMemoryKind)->throws MojoFloat32BufferOwner"
            case .sessionBorrowedMutableFloat32Buffers:
                "(MojoSessionOwner,[Float],inout [Float])->throws Void"
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
        case session(
            package: String,
            create: String,
            shutdown: String
        )
        case sessionExternal(
            package: String,
            function: String,
            sessionFactory: String
        )
        case sessionResource(
            package: String,
            create: String,
            shutdown: String,
            copyFromHost: String,
            copyToHost: String,
            synchronize: String,
            sessionFactory: String
        )

        package var canonicalRecord: String {
            switch self {
            case .inline(let operation):
                "inline:\(operation.rawValue)"
            case .external(let package, let function):
                "external:\(package).\(function)"
            case .session(let package, let create, let shutdown):
                "session:\(package).\(create):\(shutdown)"
            case .sessionExternal(
                let package,
                let function,
                let sessionFactory
            ):
                "session-external:\(package).\(function):factory=\(sessionFactory)"
            case .sessionResource(
                let package,
                let create,
                let shutdown,
                let copyFromHost,
                let copyToHost,
                let synchronize,
                let sessionFactory
            ):
                "session-resource:\(package).\(create):\(shutdown):copy-from-host=\(copyFromHost):copy-to-host=\(copyToHost):synchronize=\(synchronize):factory=\(sessionFactory)"
            }
        }
    }

    package static let schemaVersion = 3

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
        case .external, .session, .sessionExternal, .sessionResource:
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

    package var inputBufferName: String {
        precondition(signature == .borrowedMutableFloat32Buffers)
        return parameterNames[0]
    }

    package var outputBufferName: String {
        precondition(signature == .borrowedMutableFloat32Buffers)
        return parameterNames[1]
    }

    package var doubleInputBufferName: String {
        precondition(signature == .borrowedMutableFloat64Buffers)
        return parameterNames[0]
    }

    package var doubleOutputBufferName: String {
        precondition(signature == .borrowedMutableFloat64Buffers)
        return parameterNames[1]
    }

    package var requirementsName: String {
        precondition(signature == .runtimeSessionFactory)
        return parameterNames[0]
    }

    package var sessionName: String {
        precondition(signature == .sessionBorrowedMutableFloat32Buffers)
        return parameterNames[0]
    }

    package var resourceSessionName: String {
        precondition(signature == .sessionFloat32BufferFactory)
        return parameterNames[0]
    }

    package var resourceElementCountName: String {
        precondition(signature == .sessionFloat32BufferFactory)
        return parameterNames[1]
    }

    package var resourceMemoryKindName: String {
        precondition(signature == .sessionFloat32BufferFactory)
        return parameterNames[2]
    }

    package var sessionInputBufferName: String {
        precondition(signature == .sessionBorrowedMutableFloat32Buffers)
        return parameterNames[1]
    }

    package var sessionOutputBufferName: String {
        precondition(signature == .sessionBorrowedMutableFloat32Buffers)
        return parameterNames[2]
    }

    private static func implementation(
        function: FunctionDeclSyntax,
        signature: Signature,
        parameterNames: [String]
    ) throws -> Implementation {
        let invalidArgumentsError: MojoBindingError = switch signature {
        case .runtimeSessionFactory, .sessionFloat32BufferFactory,
                .sessionBorrowedMutableFloat32Buffers:
            .invalidSessionArguments
        case .int32Binary, .borrowedFloat32Buffer,
                .borrowedMutableFloat32Buffers,
                .borrowedMutableFloat64Buffers:
            .invalidExternalArguments
        }
        let arguments = try mojoArguments(
            function: function,
            invalidArgumentsError: invalidArgumentsError
        )
        if !arguments.isEmpty {
            let package: String
            let externalFunction: String
            let sessionShutdown: String?
            let resourceCopyFromHost: String?
            let resourceCopyToHost: String?
            let resourceSynchronize: String?
            let sessionFactory: String?
            if signature == .runtimeSessionFactory {
                guard arguments.count == 3,
                      let parsedPackage = arguments["package"],
                      let parsedFunction = arguments["function"],
                      let parsedShutdown = arguments["shutdown"] else {
                    throw MojoBindingError.invalidSessionArguments
                }
                package = parsedPackage
                externalFunction = parsedFunction
                sessionShutdown = parsedShutdown
                resourceCopyFromHost = nil
                resourceCopyToHost = nil
                resourceSynchronize = nil
                sessionFactory = nil
            } else if signature == .sessionFloat32BufferFactory {
                guard arguments.count == 7,
                      let parsedPackage = arguments["package"],
                      let parsedFunction = arguments["function"],
                      let parsedShutdown = arguments["shutdown"],
                      let parsedCopyFromHost = arguments["copyFromHost"],
                      let parsedCopyToHost = arguments["copyToHost"],
                      let parsedSynchronize = arguments["synchronize"],
                      let parsedFactory = arguments["sessionFactory"] else {
                    throw MojoBindingError.invalidSessionArguments
                }
                package = parsedPackage
                externalFunction = parsedFunction
                sessionShutdown = parsedShutdown
                resourceCopyFromHost = parsedCopyFromHost
                resourceCopyToHost = parsedCopyToHost
                resourceSynchronize = parsedSynchronize
                sessionFactory = parsedFactory
            } else if signature == .sessionBorrowedMutableFloat32Buffers {
                guard arguments.count == 3,
                      let parsedPackage = arguments["package"],
                      let parsedFunction = arguments["function"],
                      let parsedFactory = arguments["sessionFactory"] else {
                    throw MojoBindingError.invalidSessionArguments
                }
                package = parsedPackage
                externalFunction = parsedFunction
                sessionShutdown = nil
                resourceCopyFromHost = nil
                resourceCopyToHost = nil
                resourceSynchronize = nil
                sessionFactory = parsedFactory
            } else {
                guard arguments.count == 2,
                      let parsedPackage = arguments["package"],
                      let parsedFunction = arguments["function"] else {
                    throw MojoBindingError.invalidExternalArguments
                }
                package = parsedPackage
                externalFunction = parsedFunction
                sessionShutdown = nil
                resourceCopyFromHost = nil
                resourceCopyToHost = nil
                resourceSynchronize = nil
                sessionFactory = nil
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
            if let sessionShutdown,
               let resourceCopyFromHost,
               let resourceCopyToHost,
               let resourceSynchronize,
               let sessionFactory {
                guard MojoPortableIdentifier.isValid(sessionShutdown) else {
                    throw MojoBindingError.unsupportedExternalFunctionName(
                        sessionShutdown
                    )
                }
                guard Self.isCIdentifier(sessionFactory) else {
                    throw MojoBindingError.unsupportedSessionFactoryName(
                        sessionFactory
                    )
                }
                guard MojoPortableIdentifier.isValid(resourceCopyFromHost) else {
                    throw MojoBindingError.unsupportedExternalFunctionName(
                        resourceCopyFromHost
                    )
                }
                guard MojoPortableIdentifier.isValid(resourceCopyToHost) else {
                    throw MojoBindingError.unsupportedExternalFunctionName(
                        resourceCopyToHost
                    )
                }
                guard MojoPortableIdentifier.isValid(resourceSynchronize) else {
                    throw MojoBindingError.unsupportedExternalFunctionName(
                        resourceSynchronize
                    )
                }
                return .sessionResource(
                    package: package,
                    create: externalFunction,
                    shutdown: sessionShutdown,
                    copyFromHost: resourceCopyFromHost,
                    copyToHost: resourceCopyToHost,
                    synchronize: resourceSynchronize,
                    sessionFactory: sessionFactory
                )
            }
            if let sessionShutdown {
                guard MojoPortableIdentifier.isValid(sessionShutdown) else {
                    throw MojoBindingError.unsupportedExternalFunctionName(
                        sessionShutdown
                    )
                }
                return .session(
                    package: package,
                    create: externalFunction,
                    shutdown: sessionShutdown
                )
            }
            if let sessionFactory {
                guard Self.isCIdentifier(sessionFactory) else {
                    throw MojoBindingError.unsupportedSessionFactoryName(
                        sessionFactory
                    )
                }
                return .sessionExternal(
                    package: package,
                    function: externalFunction,
                    sessionFactory: sessionFactory
                )
            }
            return .external(
                package: package,
                function: externalFunction
            )
        }

        if signature == .runtimeSessionFactory
            || signature == .sessionFloat32BufferFactory {
            throw MojoBindingError.sessionRequiresExternalImplementation
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
        function: FunctionDeclSyntax,
        invalidArgumentsError: MojoBindingError
    ) throws -> [String: String] {
        guard let attribute = function.attributes.compactMap({ element in
            element.as(AttributeSyntax.self)
        }).first(where: {
            $0.attributeName.trimmedDescription == "mojo"
        }), let arguments = attribute.arguments else {
            return [:]
        }
        guard case .argumentList(let list) = arguments else {
            throw invalidArgumentsError
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
                throw invalidArgumentsError
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

    private static func isBorrowedFloat32BufferParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "[Float]"
    }

    private static func isMutableFloat32BufferParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "inout [Float]"
    }

    private static func isBorrowedFloat64BufferParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "[Double]"
    }

    private static func isMutableFloat64BufferParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "inout [Double]"
    }

    private static func isSessionRequirementsParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "MojoSessionRequirements"
    }

    private static func isSessionOwnerParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "MojoSessionOwner"
    }

    private static func isUInt64Parameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "UInt64"
    }

    private static func isBufferMemoryKindParameter(
        _ parameter: FunctionParameterSyntax
    ) -> Bool {
        parameter.ellipsis == nil
            && parameter.defaultValue == nil
            && parameter.type.trimmedDescription == "MojoBufferMemoryKind"
    }

    private static func signature(
        function: FunctionDeclSyntax
    ) throws -> Signature {
        let parameters = function.signature.parameterClause.parameters
        let returnType = function.signature.returnClause?.type
            .trimmedDescription
        let throwsClause = function.signature.effectSpecifiers?.throwsClause
        let isUntypedThrowing = throwsClause?.trimmedDescription == "throws"

        if parameters.count == 3 {
            let session = parameters[parameters.startIndex]
            let input = parameters[parameters.index(after: parameters.startIndex)]
            let output = parameters[parameters.index(
                parameters.startIndex,
                offsetBy: 2
            )]
            if Self.isSessionOwnerParameter(session),
               Self.isBorrowedFloat32BufferParameter(input),
               Self.isMutableFloat32BufferParameter(output),
               returnType == nil || returnType == "Void",
               isUntypedThrowing {
                return .sessionBorrowedMutableFloat32Buffers
            }
            if Self.isSessionOwnerParameter(session),
               Self.isUInt64Parameter(input),
               Self.isBufferMemoryKindParameter(output),
               returnType == "MojoFloat32BufferOwner",
               isUntypedThrowing {
                return .sessionFloat32BufferFactory
            }
            throw MojoBindingError.unsupportedSignature
        }

        if parameters.count == 2 {
            let lhs = parameters[parameters.startIndex]
            let rhs = parameters[parameters.index(after: parameters.startIndex)]
            if Self.isInt32Parameter(lhs),
               Self.isInt32Parameter(rhs),
               returnType == "Int32" {
                guard throwsClause == nil else {
                    throw MojoBindingError.throwingUnsupported
                }
                return .int32Binary
            }
            if Self.isBorrowedFloat32BufferParameter(lhs),
               Self.isMutableFloat32BufferParameter(rhs),
               returnType == nil || returnType == "Void",
               isUntypedThrowing {
                return .borrowedMutableFloat32Buffers
            }
            if Self.isBorrowedFloat64BufferParameter(lhs),
               Self.isMutableFloat64BufferParameter(rhs),
               returnType == nil || returnType == "Void",
               isUntypedThrowing {
                return .borrowedMutableFloat64Buffers
            }
            throw MojoBindingError.unsupportedSignature
        }

        if parameters.count == 1,
           let parameter = parameters.first,
           Self.isBorrowedFloat32BufferParameter(parameter),
           returnType == "Float",
           isUntypedThrowing {
            return .borrowedFloat32Buffer
        }

        if parameters.count == 1,
           let parameter = parameters.first,
           Self.isSessionRequirementsParameter(parameter),
           returnType == "MojoSessionOwner",
           isUntypedThrowing {
            return .runtimeSessionFactory
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
