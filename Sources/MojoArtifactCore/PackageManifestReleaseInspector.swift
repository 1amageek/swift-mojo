import Foundation
import MojoBindingCore
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

package enum PackageManifestReleaseInspector {
    private struct ManifestSnapshot {
        let syntax: Syntax
        let digest: String
    }

    package static func validateReleaseIntegration(
        packageRootURL: URL,
        targetName: String,
        binaryTargetName: String,
        binaryTargetPath: String
    ) throws -> String {
        let manifest = try manifestSyntax(packageRootURL: packageRootURL)
        let package = try packageDeclaration(in: manifest.syntax)
        guard !containsConditionalCompilation(in: Syntax(package)) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "the Package declaration cannot use conditional compilation"
            )
        }
        let packageDependencies = try literalArrayArgument(
            label: "dependencies",
            in: package,
            required: false
        )
        guard !containsLocalPackageDependency(in: packageDependencies) else {
            throw MojoArtifactError.localPackageDependencyInRelease
        }
        let targetExpressions = try literalArrayArgument(
            label: "targets",
            in: package,
            required: true
        )
        let targetDeclarations = targetExpressions.compactMap {
            $0.as(FunctionCallExprSyntax.self)
        }
        let supportedTargetFactories: Set<String> = [
            "binaryTarget", "executableTarget", "macro", "plugin",
            "systemLibrary", "target", "testTarget",
        ]
        guard targetDeclarations.count == targetExpressions.count,
              targetDeclarations.allSatisfy({ call in
                functionName(call).map(supportedTargetFactories.contains)
                    == true
              }) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "Package targets must use literal PackageDescription target declarations"
            )
        }
        let binaryTargets = targetDeclarations.filter {
            functionName($0) == "binaryTarget"
                && stringArgument(label: "name", in: $0) == binaryTargetName
        }
        guard binaryTargets.count == 1,
              let binaryTarget = binaryTargets.first else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "expected exactly one binaryTarget named '\(binaryTargetName)'"
            )
        }
        guard stringArgument(label: "path", in: binaryTarget)
                == binaryTargetPath else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "binaryTarget '\(binaryTargetName)' must use path '\(binaryTargetPath)'"
            )
        }

        let sourceTargets = targetDeclarations.filter {
            guard let name = functionName($0),
                  name == "target" || name == "executableTarget" else {
                return false
            }
            return stringArgument(label: "name", in: $0) == targetName
                && argument(label: "dependencies", in: $0) != nil
                && argument(label: "plugins", in: $0) != nil
        }
        guard sourceTargets.count == 1,
              let sourceTarget = sourceTargets.first else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "target '\(targetName)' must declare dependencies and plugins explicitly"
            )
        }
        guard arrayArgument(
            label: "dependencies",
            in: sourceTarget
        ).contains(where: {
            dependency($0, references: binaryTargetName)
        }) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "target '\(targetName)' must depend on '\(binaryTargetName)'"
            )
        }
        guard arrayArgument(
            label: "plugins",
            in: sourceTarget
        ).contains(where: {
            guard let call = $0.as(FunctionCallExprSyntax.self) else {
                return false
            }
            return functionName(call) == "plugin"
                && stringArgument(label: "name", in: call)
                    == "MojoBuildPlugin"
        }) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "target '\(targetName)' must apply MojoBuildPlugin"
            )
        }
        return manifest.digest
    }

    private static func containsLocalPackageDependency(
        in dependencies: [ExprSyntax]
    ) -> Bool {
        dependencies.contains { expression in
            guard let call = expression.as(FunctionCallExprSyntax.self),
                  functionName(call) == "package" else {
                return true
            }
            if call.arguments.contains(where: { $0.label?.text == "path" }) {
                return true
            }
            if argument(label: "url", in: call) != nil {
                guard let url = stringArgument(label: "url", in: call) else {
                    return true
                }
                guard isLiteralRemotePackageURL(url) else {
                    return true
                }
            }
            let hasRegistryIdentity = stringArgument(label: "id", in: call)
                .map { !$0.isEmpty } ?? false
            let hasRemoteURL = stringArgument(label: "url", in: call) != nil
            return !hasRegistryIdentity && !hasRemoteURL
        }
    }

    private static func isLiteralRemotePackageURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["git", "http", "https", "ssh"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func manifestSyntax(
        packageRootURL: URL
    ) throws -> ManifestSnapshot {
        let manifestURL = packageRootURL.appendingPathComponent("Package.swift")
        do {
            try MojoRegularFile.validate(at: manifestURL)
            let data = try Data(contentsOf: manifestURL)
            guard let source = String(data: data, encoding: .utf8) else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "'\(manifestURL.path)' is not valid UTF-8"
                )
            }
            let parsed = Parser.parse(source: source)
            let diagnostics = ParseDiagnosticsGenerator.diagnostics(
                for: parsed
            )
            guard diagnostics.isEmpty else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "'\(manifestURL.path)' contains \(diagnostics.count) Swift parse diagnostic(s)"
                )
            }
            return ManifestSnapshot(
                syntax: Syntax(parsed),
                digest: MojoCanonicalDigest.hex(data)
            )
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "cannot read '\(manifestURL.path)': \(error)"
            )
        }
    }

    private static func packageDeclaration(
        in syntax: Syntax
    ) throws -> FunctionCallExprSyntax {
        guard let sourceFile = syntax.as(SourceFileSyntax.self) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "Package.swift did not parse as a source file"
            )
        }
        var declarations: [FunctionCallExprSyntax] = []
        for statement in sourceFile.statements {
            guard let variable = statement.item.as(VariableDeclSyntax.self)
            else {
                continue
            }
            for binding in variable.bindings {
                guard binding.pattern.as(IdentifierPatternSyntax.self)?
                        .identifier.text == "package",
                      let call = binding.initializer?.value.as(
                        FunctionCallExprSyntax.self
                      ),
                      functionName(call) == "Package" else {
                    continue
                }
                declarations.append(call)
            }
        }
        guard declarations.count == 1,
              let declaration = declarations.first else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "expected exactly one top-level Package initializer named 'package'"
            )
        }
        return declaration
    }

    private static func literalArrayArgument(
        label: String,
        in call: FunctionCallExprSyntax,
        required: Bool
    ) throws -> [ExprSyntax] {
        guard let expression = argument(label: label, in: call)?.expression else {
            if required {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "Package must declare a literal '\(label)' array"
                )
            }
            return []
        }
        guard let array = expression.as(ArrayExprSyntax.self) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "Package '\(label)' must be a literal array"
            )
        }
        return array.elements.map(\.expression)
    }

    private static func containsConditionalCompilation(in syntax: Syntax) -> Bool {
        if syntax.is(IfConfigDeclSyntax.self) {
            return true
        }
        return syntax.children(viewMode: .sourceAccurate).contains { child in
            containsConditionalCompilation(in: child)
        }
    }

    private static func functionName(
        _ call: FunctionCallExprSyntax
    ) -> String? {
        if let member = call.calledExpression.as(MemberAccessExprSyntax.self) {
            return member.declName.baseName.text
        }
        return call.calledExpression.as(DeclReferenceExprSyntax.self)?
            .baseName.text
    }

    private static func argument(
        label: String,
        in call: FunctionCallExprSyntax
    ) -> LabeledExprSyntax? {
        call.arguments.first { $0.label?.text == label }
    }

    private static func stringArgument(
        label: String,
        in call: FunctionCallExprSyntax
    ) -> String? {
        guard let expression = argument(label: label, in: call)?.expression,
              let literal = expression.as(StringLiteralExprSyntax.self),
              literal.segments.count == 1,
              let segment = literal.segments.first?.as(
                StringSegmentSyntax.self
              ) else {
            return nil
        }
        return segment.content.text
    }

    private static func arrayArgument(
        label: String,
        in call: FunctionCallExprSyntax
    ) -> [ExprSyntax] {
        guard let expression = argument(label: label, in: call)?.expression,
              let array = expression.as(ArrayExprSyntax.self) else {
            return []
        }
        return array.elements.map(\.expression)
    }

    private static func dependency(
        _ expression: ExprSyntax,
        references targetName: String
    ) -> Bool {
        if let literal = expression.as(StringLiteralExprSyntax.self),
           literal.segments.count == 1,
           let segment = literal.segments.first?.as(
            StringSegmentSyntax.self
           ) {
            return segment.content.text == targetName
        }
        guard let call = expression.as(FunctionCallExprSyntax.self) else {
            return false
        }
        guard let name = functionName(call),
              name == "target" || name == "byName" else {
            return false
        }
        return stringArgument(label: "name", in: call) == targetName
    }
}
