import Foundation
import MojoCompilerCore

package struct MojoObjectLinkageInspector: Sendable {
    package static let policyVersion = 1

    private let processRunner: any MojoProcessRunning

    package init(processRunner: any MojoProcessRunning) {
        self.processRunner = processRunner
    }

    package func validate(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
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

        let unsupportedSymbols = Set(
            result.output.split(whereSeparator: \Character.isNewline)
                .compactMap(Self.symbol(from:))
                .filter { $0.hasPrefix("KGEN_CompilerRT_") }
        ).sorted()
        guard unsupportedSymbols.isEmpty else {
            throw MojoArtifactError.unsupportedMojoRuntimeSymbols(
                target: target.identity,
                symbols: unsupportedSymbols
            )
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
