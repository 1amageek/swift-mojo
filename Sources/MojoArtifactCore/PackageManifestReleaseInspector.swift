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
        try validateReleaseIntegration(
            packageRootURL: packageRootURL,
            targetName: targetName,
            binaryIntegrations: [
                MojoPackageBinaryIntegration(
                    adapter: .appleXCFramework,
                    binaryTargetName: binaryTargetName,
                    binaryTargetPath: binaryTargetPath,
                    platforms: []
                ),
            ]
        )
    }

    package static func validateReleaseIntegration(
        packageRootURL: URL,
        targetName: String,
        binaryIntegrations: [MojoPackageBinaryIntegration]
    ) throws -> String {
        guard !binaryIntegrations.isEmpty else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "at least one native binary integration is required"
            )
        }
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
        let packageReferences = try releasePackageReferences(
            in: packageDependencies
        )
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
        for integration in binaryIntegrations {
            let binaryTargets = targetDeclarations.filter {
                functionName($0) == "binaryTarget"
                    && stringArgument(label: "name", in: $0)
                        == integration.binaryTargetName
            }
            guard binaryTargets.count == 1,
                  let binaryTarget = binaryTargets.first else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "expected exactly one binaryTarget named '\(integration.binaryTargetName)'"
                )
            }
            guard stringArgument(label: "path", in: binaryTarget)
                    == integration.binaryTargetPath else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "binaryTarget '\(integration.binaryTargetName)' must use path '\(integration.binaryTargetPath)'"
                )
            }
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
        let sourceDependencies = arrayArgument(
            label: "dependencies",
            in: sourceTarget
        )
        for integration in binaryIntegrations {
            let matches = sourceDependencies.filter {
                dependency($0, references: integration.binaryTargetName)
            }
            guard matches.count == 1, let match = matches.first else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "target '\(targetName)' must depend exactly once on '\(integration.binaryTargetName)'"
                )
            }
            if binaryIntegrations.count > 1,
               dependencyPlatforms(match) != integration.platforms {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "target '\(targetName)' dependency '\(integration.binaryTargetName)' must use platforms \(integration.platforms.sorted())"
                )
            }
        }
        let mojoPackageReferences = sourceDependencies.compactMap {
            productPackageReference($0, productName: "Mojo")
        }
        guard mojoPackageReferences.count == 1,
              let mojoPackageReference = mojoPackageReferences.first,
              packageReferences.contains(mojoPackageReference) else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "target '\(targetName)' must depend on the Mojo product from one declared remote package"
            )
        }
        let plugins = arrayArgument(
            label: "plugins",
            in: sourceTarget
        )
        let matchingPlugins = plugins.filter {
            pluginPackageReference($0, pluginName: "MojoBuildPlugin")
                == mojoPackageReference
        }
        guard matchingPlugins.count == 1 else {
            throw MojoArtifactError.packageManifestIntegrationMismatch(
                "target '\(targetName)' must apply MojoBuildPlugin from the same package as the Mojo product"
            )
        }
        return manifest.digest
    }

    private static func releasePackageReferences(
        in dependencies: [ExprSyntax]
    ) throws -> Set<String> {
        var references: Set<String> = []
        for expression in dependencies {
            guard let call = expression.as(FunctionCallExprSyntax.self),
                  functionName(call) == "package" else {
                throw MojoArtifactError.localPackageDependencyInRelease
            }
            if call.arguments.contains(where: { $0.label?.text == "path" }) {
                throw MojoArtifactError.localPackageDependencyInRelease
            }
            let explicitName = stringArgument(label: "name", in: call)
            let reference: String
            if argument(label: "url", in: call) != nil {
                guard let url = stringArgument(label: "url", in: call) else {
                    throw MojoArtifactError.localPackageDependencyInRelease
                }
                guard isLiteralRemotePackageURL(url) else {
                    throw MojoArtifactError.localPackageDependencyInRelease
                }
                guard let derivedName = packageIdentity(fromRemoteURL: url) else {
                    throw MojoArtifactError.localPackageDependencyInRelease
                }
                reference = explicitName ?? derivedName
            } else if let identity = stringArgument(label: "id", in: call),
                      identity.isEmpty == false {
                reference = explicitName ?? identity
            } else {
                throw MojoArtifactError.localPackageDependencyInRelease
            }
            if let branch = stringArgument(label: "branch", in: call) {
                throw MojoArtifactError.mutablePackageDependencyInRelease(
                    branch
                )
            }
            let requirementLabels = ["from", "exact", "revision"]
            let requirements = requirementLabels.compactMap { label in
                stringArgument(label: label, in: call).map { (label, $0) }
            }
            guard requirements.count == 1,
                  requirements[0].1.isEmpty == false else {
                throw MojoArtifactError.localPackageDependencyInRelease
            }
            let requirement = requirements[0]
            let isValidRequirement = requirement.0 == "revision"
                ? isFullGitObjectID(requirement.1)
                : isSemanticVersion(requirement.1)
            guard isValidRequirement else {
                throw MojoArtifactError.invalidPackageDependencyRequirement(
                    "\(requirement.0): \(requirement.1)"
                )
            }
            guard references.insert(reference).inserted else {
                throw MojoArtifactError.packageManifestIntegrationMismatch(
                    "Package dependencies contain duplicate reference name '\(reference)'"
                )
            }
        }
        return references
    }

    private static func isFullGitObjectID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 40 || bytes.count == 64 else {
            return false
        }
        return bytes.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 70)
                || (byte >= 97 && byte <= 102)
        }
    }

    private static func isSemanticVersion(_ value: String) -> Bool {
        let buildParts = value.split(
            separator: "+",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard buildParts.count <= 2,
              !buildParts[0].isEmpty else {
            return false
        }
        if buildParts.count == 2,
           !isDotSeparatedIdentifiers(
            buildParts[1],
            numericLeadingZerosAllowed: true
           ) {
            return false
        }
        let releaseParts = buildParts[0].split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard !releaseParts[0].isEmpty else {
            return false
        }
        if releaseParts.count == 2,
           !isDotSeparatedIdentifiers(
            releaseParts[1],
            numericLeadingZerosAllowed: false
           ) {
            return false
        }
        let core = releaseParts[0].split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard core.count == 3 else {
            return false
        }
        return core.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return false
            }
            return identifier == "0" || identifier.first != "0"
        }
    }

    private static func isDotSeparatedIdentifiers(
        _ value: Substring,
        numericLeadingZerosAllowed: Bool
    ) -> Bool {
        let identifiers = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return !identifiers.isEmpty && identifiers.allSatisfy { identifier in
            guard !identifier.isEmpty,
                  identifier.utf8.allSatisfy({ byte in
                    (byte >= 48 && byte <= 57)
                        || (byte >= 65 && byte <= 90)
                        || (byte >= 97 && byte <= 122)
                        || byte == 45
                  }) else {
                return false
            }
            let isNumeric = identifier.utf8.allSatisfy {
                $0 >= 48 && $0 <= 57
            }
            return numericLeadingZerosAllowed
                || !isNumeric
                || identifier == "0"
                || identifier.first != "0"
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

    private static func packageIdentity(fromRemoteURL value: String) -> String? {
        guard let components = URLComponents(string: value),
              let pathComponent = components.path.split(separator: "/").last else {
            return nil
        }
        let name = String(pathComponent)
        let identity = name.hasSuffix(".git")
            ? String(name.dropLast(4))
            : name
        return identity.isEmpty ? nil : identity
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

    private static func dependencyPlatforms(
        _ expression: ExprSyntax
    ) -> Set<String>? {
        guard let dependency = expression.as(FunctionCallExprSyntax.self),
              let conditionExpression = argument(
                label: "condition",
                in: dependency
              )?.expression,
              let condition = conditionExpression.as(
                FunctionCallExprSyntax.self
              ),
              functionName(condition) == "when",
              let platformsExpression = argument(
                label: "platforms",
                in: condition
              )?.expression,
              let platforms = platformsExpression.as(ArrayExprSyntax.self)
        else {
            return nil
        }
        let names = platforms.elements.compactMap { element in
            element.expression.as(MemberAccessExprSyntax.self)?
                .declName.baseName.text
        }
        guard names.count == platforms.elements.count else {
            return nil
        }
        return Set(names)
    }

    private static func productPackageReference(
        _ expression: ExprSyntax,
        productName: String
    ) -> String? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              functionName(call) == "product",
              stringArgument(label: "name", in: call) == productName else {
            return nil
        }
        return stringArgument(label: "package", in: call)
    }

    private static func pluginPackageReference(
        _ expression: ExprSyntax,
        pluginName: String
    ) -> String? {
        guard let call = expression.as(FunctionCallExprSyntax.self),
              functionName(call) == "plugin",
              stringArgument(label: "name", in: call) == pluginName else {
            return nil
        }
        return stringArgument(label: "package", in: call)
    }
}
