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
}
