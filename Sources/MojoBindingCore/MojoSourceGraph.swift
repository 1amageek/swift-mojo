import Foundation
import SwiftParser
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
        let canonical = sorted.map(\.canonicalRecord).joined(separator: "\n")
        self.bindings = sorted
        self.digest = MojoCanonicalDigest.hex(canonical)
        self.digestIdentifier = MojoCanonicalDigest.identifier(canonical)
    }

    package init(sourceURLs: [URL]) throws {
        var bindings: [MojoBinding] = []
        for sourceURL in sourceURLs.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let sourceFile = Parser.parse(source: source)
            try Self.collectBindings(
                in: Syntax(sourceFile),
                isConditionallyCompiled: false,
                into: &bindings
            )
        }
        try self.init(bindings: bindings)
    }

    private static func collectBindings(
        in syntax: Syntax,
        isConditionallyCompiled: Bool,
        into bindings: inout [MojoBinding]
    ) throws {
        if let function = syntax.as(FunctionDeclSyntax.self),
           MojoBinding.isInlineMojoFunction(function) {
            guard !isConditionallyCompiled else {
                throw MojoBindingError.conditionalCompilationUnsupported
            }
            bindings.append(try MojoBinding(function: function))
            return
        }
        let childIsConditionallyCompiled = isConditionallyCompiled
            || syntax.is(IfConfigDeclSyntax.self)
        for child in syntax.children(viewMode: .sourceAccurate) {
            try collectBindings(
                in: child,
                isConditionallyCompiled: childIsConditionallyCompiled,
                into: &bindings
            )
        }
    }
}
