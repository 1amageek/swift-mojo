import Foundation
import MojoCompilerCore

package struct MojoRuntimeReceiptOptions: Equatable, Sendable {
    package let objectURL: URL
    package let libraryURLs: [URL]
    package let target: MojoTargetConfiguration
    package let allowedSystemDependencies: Set<String>

    package init(
        objectURL: URL,
        libraryURLs: [URL],
        target: MojoTargetConfiguration,
        allowedSystemDependencies: Set<String> = []
    ) throws {
        guard !libraryURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one --runtime-library path is required"
            )
        }
        let normalizedObject = objectURL.standardizedFileURL
        let normalizedLibraries = libraryURLs.map(\.standardizedFileURL)
            .sorted { $0.path < $1.path }
        guard Set(normalizedLibraries.map(\.path)).count
                == normalizedLibraries.count else {
            throw MojoArtifactError.invalidArguments(
                "Runtime library paths must be unique"
            )
        }
        guard Set(normalizedLibraries.map(\.lastPathComponent)).count
                == normalizedLibraries.count else {
            throw MojoArtifactError.invalidArguments(
                "Runtime library filenames must be unique"
            )
        }
        guard allowedSystemDependencies.allSatisfy({
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw MojoArtifactError.invalidArguments(
                "System dependency names cannot be empty"
            )
        }
        if !allowedSystemDependencies.isEmpty {
            guard target.triple.lowercased().contains("-linux-") else {
                throw MojoArtifactError.invalidArguments(
                    "Explicit system dependencies are supported only for Linux SONAMEs"
                )
            }
            guard allowedSystemDependencies.allSatisfy({ dependency in
                dependency == URL(fileURLWithPath: dependency).lastPathComponent
                    && !dependency.hasPrefix("@")
                    && Self.isSafeLinuxSONAME(dependency)
            }) else {
                throw MojoArtifactError.invalidArguments(
                    "Explicit system dependencies must be bare Linux SONAMEs"
                )
            }
        }
        self.objectURL = normalizedObject
        self.libraryURLs = normalizedLibraries
        self.target = target
        self.allowedSystemDependencies = allowedSystemDependencies
    }

    private static func isSafeLinuxSONAME(_ value: String) -> Bool {
        let bytes = value.utf8
        guard !bytes.isEmpty,
              bytes.count <= 255,
              let first = bytes.first,
              isASCIILetterOrDigit(first) else {
            return false
        }
        return bytes.allSatisfy { byte in
            isASCIILetterOrDigit(byte)
                || byte == 43
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }
}
