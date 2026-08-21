import Foundation
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

package struct MojoSourceGraph: Equatable, Sendable {
    package let bindings: [MojoBinding]
    package let digest: String
    package let digestIdentifier: UInt64

    package init(bindings: [MojoBinding]) throws {
        let sorted = bindings.sorted {
            if $0.bindingID == $1.bindingID {
                return $0.implementationDigest < $1.implementationDigest
            }
            return $0.bindingID < $1.bindingID
        }
        guard !sorted.isEmpty else {
            throw MojoBindingError.noBindings
        }
        var seen: Set<UInt64> = []
        for binding in sorted {
            guard seen.insert(binding.bindingID).inserted else {
                throw MojoBindingError.duplicateBindingID(binding.bindingID)
            }
        }
        let sessionFactories: [String: String] = Dictionary(
            uniqueKeysWithValues: sorted.compactMap { binding -> (String, String)? in
                guard case .session(let package, _, _) = binding.implementation else {
                    return nil
                }
                return (binding.functionName, package)
            }
        )
        for binding in sorted {
            let package: String
            let sessionFactory: String
            switch binding.implementation {
            case .sessionExternal(
                let bindingPackage,
                _,
                let bindingSessionFactory
            ), .sessionResource(
                let bindingPackage,
                _,
                _,
                _,
                _,
                _,
                let bindingSessionFactory
            ):
                package = bindingPackage
                sessionFactory = bindingSessionFactory
            case .inline, .external, .session:
                continue
            }
            guard let factoryPackage = sessionFactories[sessionFactory] else {
                throw MojoBindingError.sessionFactoryNotFound(sessionFactory)
            }
            guard factoryPackage == package else {
                throw MojoBindingError.sessionPackageMismatch(
                    binding: package,
                    factory: factoryPackage
                )
            }
        }
        let canonical = sorted.map(\.canonicalRecord).joined(separator: "\n")
        self.bindings = sorted
        self.digest = MojoCanonicalDigest.hex(canonical)
        self.digestIdentifier = MojoCanonicalDigest.identifier(canonical)
    }

    package init(
        sourceURLs: [URL],
        sourceRootURL: URL? = nil
    ) throws {
        var bindings: [MojoBinding] = []
        let canonicalSourceRootURL = sourceRootURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for sourceURL in sourceURLs.sorted(by: { $0.path < $1.path }) {
            let values = try sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw MojoBindingError.invalidSourceFile(sourceURL.path)
            }
            let canonicalSourceURL = sourceURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let source = try String(
                contentsOf: canonicalSourceURL,
                encoding: .utf8
            )
            let sourceFile = Parser.parse(source: source)
            let sourceIdentity = Self.sourceIdentity(
                for: canonicalSourceURL,
                rootURL: canonicalSourceRootURL
            )
            let diagnostics = ParseDiagnosticsGenerator.diagnostics(
                for: sourceFile
            )
            guard diagnostics.isEmpty else {
                throw MojoBindingError.invalidSwiftSyntax(
                    file: sourceIdentity,
                    diagnosticCount: diagnostics.count
                )
            }
            let converter = SourceLocationConverter(
                fileName: sourceIdentity,
                tree: sourceFile
            )
            try Self.collectBindings(
                in: Syntax(sourceFile),
                isConditionallyCompiled: false,
                converter: converter,
                into: &bindings
            )
        }
        try self.init(bindings: bindings)
    }

    private static func collectBindings(
        in syntax: Syntax,
        isConditionallyCompiled: Bool,
        converter: SourceLocationConverter,
        into bindings: inout [MojoBinding]
    ) throws {
        if let function = syntax.as(FunctionDeclSyntax.self),
           MojoBinding.isMojoFunction(function) {
            guard !isConditionallyCompiled else {
                throw MojoBindingError.conditionalCompilationUnsupported
            }
            guard Self.isFileScope(function) else {
                throw MojoBindingError.nonFileScopeUnsupported
            }
            let location = converter.location(
                for: function.positionAfterSkippingLeadingTrivia
            )
            bindings.append(
                try MojoBinding(
                    function: function,
                    sourceReference: MojoSourceReference(
                        file: location.file,
                        line: location.line,
                        column: location.column
                    )
                )
            )
            return
        }
        let childIsConditionallyCompiled = isConditionallyCompiled
            || syntax.is(IfConfigDeclSyntax.self)
        for child in syntax.children(viewMode: .sourceAccurate) {
            try collectBindings(
                in: child,
                isConditionallyCompiled: childIsConditionallyCompiled,
                converter: converter,
                into: &bindings
            )
        }
    }

    private static func sourceIdentity(
        for sourceURL: URL,
        rootURL: URL?
    ) -> String {
        guard let rootURL else {
            return sourceURL.lastPathComponent
        }
        let rootPath = rootURL.standardizedFileURL.path
        let sourcePath = sourceURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard sourcePath.hasPrefix(prefix) else {
            return sourceURL.lastPathComponent
        }
        return String(sourcePath.dropFirst(prefix.count))
    }

    private static func isFileScope(_ function: FunctionDeclSyntax) -> Bool {
        var ancestor = Syntax(function).parent
        while let current = ancestor {
            if current.is(MemberBlockSyntax.self)
                || current.is(CodeBlockSyntax.self) {
                return false
            }
            if current.is(SourceFileSyntax.self) {
                return true
            }
            ancestor = current.parent
        }
        return false
    }
}
