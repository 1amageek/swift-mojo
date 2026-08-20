import Foundation
import MojoBindingCore

package struct MojoSourceMap: Codable, Equatable, Sendable {
    package struct Entry: Codable, Equatable, Sendable {
        package let generatedLine: Int
        package let bindingID: UInt64
        package let source: MojoSourceReference

        package init(
            generatedLine: Int,
            bindingID: UInt64,
            source: MojoSourceReference
        ) {
            self.generatedLine = generatedLine
            self.bindingID = bindingID
            self.source = source
        }
    }

    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let generatedFile: String
    package let inputGraphDigest: String
    package let entries: [Entry]

    package init(inputGraphDigest: String, entries: [Entry]) {
        self.schemaVersion = Self.currentSchemaVersion
        self.generatedFile = "Bindings.mojo"
        self.inputGraphDigest = inputGraphDigest
        self.entries = entries.sorted { $0.generatedLine < $1.generatedLine }
    }

    package func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    package func remap(
        diagnostic: String,
        generatedSourcePath: String? = nil
    ) -> String {
        var result = diagnostic
        for entry in entries {
            let source = "\(entry.source.file):\(entry.source.line):\(entry.source.column):"
            let lineSuffix = ":\(entry.generatedLine):"
            if let generatedSourcePath {
                result = Self.replacingLocation(
                    in: result,
                    generatedPrefix: generatedSourcePath + lineSuffix,
                    source: source
                )
            }
            result = Self.replacingLocation(
                in: result,
                generatedPrefix: generatedFile + lineSuffix,
                source: source
            )
        }
        return result
    }

    private static func replacingLocation(
        in diagnostic: String,
        generatedPrefix: String,
        source: String
    ) -> String {
        var result = diagnostic
        while let prefixRange = result.range(of: generatedPrefix) {
            let columnStart = prefixRange.upperBound
            if let columnEnd = result[columnStart...].firstIndex(of: ":"),
               !result[columnStart..<columnEnd].isEmpty,
               result[columnStart..<columnEnd].allSatisfy(\.isNumber) {
                result.replaceSubrange(
                    prefixRange.lowerBound...columnEnd,
                    with: source
                )
            } else {
                result.replaceSubrange(prefixRange, with: source)
            }
        }
        return result
    }
}
