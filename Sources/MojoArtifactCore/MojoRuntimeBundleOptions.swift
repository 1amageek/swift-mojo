import Foundation
import MojoCompilerCore

package struct MojoRuntimeBundleOptions: Equatable, Sendable {
    package let outputDirectoryURL: URL
    package let executableName: String
    package let runtimeReceiptOptions: MojoRuntimeReceiptOptions

    package var objectURL: URL { runtimeReceiptOptions.objectURL }
    package var libraryURLs: [URL] { runtimeReceiptOptions.libraryURLs }
    package var target: MojoTargetConfiguration { runtimeReceiptOptions.target }

    package init(
        outputDirectoryURL: URL,
        executableName: String,
        objectURL: URL,
        libraryURLs: [URL],
        target: MojoTargetConfiguration,
        allowedSystemDependencies: Set<String> = []
    ) throws {
        guard Self.isPortableExecutableName(executableName) else {
            throw MojoArtifactError.invalidArguments(
                "The runtime executable name must be an ASCII identifier containing only letters, digits, underscores, or hyphens"
            )
        }
        let receiptOptions = try MojoRuntimeReceiptOptions(
            objectURL: objectURL,
            libraryURLs: libraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )
        let output = outputDirectoryURL.standardizedFileURL
        let outputPrefix = output.path.hasSuffix("/")
            ? output.path
            : output.path + "/"
        let inputs = [receiptOptions.objectURL] + receiptOptions.libraryURLs
        guard !inputs.contains(where: {
            $0.path == output.path || $0.path.hasPrefix(outputPrefix)
        }) else {
            throw MojoArtifactError.invalidArguments(
                "The runtime bundle output must not contain its object or library inputs"
            )
        }
        self.outputDirectoryURL = output
        self.executableName = executableName
        self.runtimeReceiptOptions = receiptOptions
    }

    private static func isPortableExecutableName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              first == 95
                || (first >= 65 && first <= 90)
                || (first >= 97 && first <= 122) else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy { codeUnit in
            codeUnit == 45
                || codeUnit == 95
                || (codeUnit >= 48 && codeUnit <= 57)
                || (codeUnit >= 65 && codeUnit <= 90)
                || (codeUnit >= 97 && codeUnit <= 122)
        }
    }
}
