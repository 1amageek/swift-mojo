import Foundation
import MojoCompilerCore

package enum MojoRuntimeWorkerLibraryPolicy {
    package static func validate(
        libraryURLs: [URL],
        target: MojoTargetConfiguration,
        moduleName: String,
        symbolPrefix: String,
        binaryInspector: any MojoRuntimeBinaryInspecting
    ) throws {
        let primaryLibraryName: String
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            primaryLibraryName = "lib\(moduleName).dylib"
        } else if triple.contains("-linux-") {
            primaryLibraryName = "lib\(moduleName).so"
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        guard !libraryURLs.contains(where: {
            $0.lastPathComponent == primaryLibraryName
        }) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker runtime closure contains the callable primary library '\(primaryLibraryName)'"
            )
        }

        let generatedSymbolPrefix = symbolPrefix + "_"
        for libraryURL in libraryURLs {
            let inspection = try binaryInspector.inspect(
                libraryURL: libraryURL,
                target: target
            )
            let generatedExports = inspection.exportedSymbols.filter {
                $0.hasPrefix(generatedSymbolPrefix)
            }.sorted()
            guard generatedExports.isEmpty else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "worker runtime library '\(libraryURL.lastPathComponent)' exports generated callable ABI symbols: \(generatedExports.joined(separator: ", "))"
                )
            }
        }
    }
}
