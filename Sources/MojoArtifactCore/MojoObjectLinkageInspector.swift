import Foundation
import MojoCompilerCore

package struct MojoObjectLinkageInspector: Sendable {
    package static let policyVersion = 2

    private static let unsupportedRuntimeSymbolPrefixes = [
        "AsyncRT_",
        "KGEN_CompilerRT_",
        "MGP_RT_",
    ]

    private let processRunner: any MojoProcessRunning

    package init(processRunner: any MojoProcessRunning) {
        self.processRunner = processRunner
    }

    package func validate(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        let unsupportedSymbols = try runtimeSymbols(
            objectURL: objectURL,
            target: target
        )
        guard unsupportedSymbols.isEmpty else {
            throw MojoArtifactError.unsupportedMojoRuntimeSymbols(
                target: target.identity,
                symbols: unsupportedSymbols
            )
        }
    }

    package func undefinedSymbols(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws -> [String] {
        let arguments = ["-u", objectURL.path]
        let result = try processRunner.capture(
            executablePath: "/usr/bin/nm",
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: (["/usr/bin/nm"] + arguments).joined(separator: " "),
                status: result.status,
                diagnostic: result.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
        return Set(
            result.output.split(whereSeparator: \Character.isNewline)
                .compactMap(Self.symbol(from:))
        ).sorted()
    }

    package func runtimeSymbols(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws -> [String] {
        try undefinedSymbols(objectURL: objectURL, target: target).filter(
            Self.isRuntimeSymbol
        )
    }

    package static func isRuntimeSymbol(_ symbol: String) -> Bool {
        unsupportedRuntimeSymbolPrefixes.contains { prefix in
            symbol.hasPrefix(prefix)
        }
    }

    private static func symbol(from line: Substring) -> String? {
        guard let token = line.split(whereSeparator: \Character.isWhitespace)
            .last else {
            return nil
        }
        let symbol = token.first == "_" ? token.dropFirst() : token[...]
        return symbol.isEmpty ? nil : String(symbol)
    }
}
