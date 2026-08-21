import Foundation
import MojoBindingCore

package struct MojoArtifactIdentity: Codable, Equatable, Sendable {
    package let targetName: String
    package let moduleName: String
    package let artifactName: String
    package let libraryName: String
    package let symbolPrefix: String

    package var linuxArtifactName: String {
        "\(moduleName).artifactbundle"
    }

    package var linuxBinaryTargetName: String {
        "\(moduleName)_Linux"
    }

    package init(targetName: String) throws {
        guard Self.isPortableTargetName(targetName) else {
            throw MojoArtifactError.invalidArguments(
                "The Mojo target identity must be an ASCII identifier containing only letters, digits, underscores, or hyphens"
            )
        }
        let moduleComponent = targetName.map { character -> Character in
            character.isLetter || character.isNumber || character == "_"
                ? character
                : "_"
        }
        let normalized = String(moduleComponent)
        let digest = MojoCanonicalDigest.hex(targetName)
        let uniqueComponent = targetName.contains("-")
            ? "\(normalized)_\(digest)"
            : normalized
        self.targetName = targetName
        self.moduleName = "SwiftMojo_\(uniqueComponent)_ABI"
        self.artifactName = "SwiftMojo_\(uniqueComponent)_ABI.xcframework"
        self.libraryName = "libSwiftMojo_\(uniqueComponent)_ABI.a"
        self.symbolPrefix = "swift_mojo_\(digest)"
    }

    package static let legacy = MojoArtifactIdentity(
        targetName: "Legacy",
        moduleName: MojoStaticABI.legacyModuleName,
        artifactName: MojoStaticABI.legacyArtifactName,
        libraryName: MojoStaticABI.legacyLibraryName,
        symbolPrefix: "swift_mojo"
    )

    private init(
        targetName: String,
        moduleName: String,
        artifactName: String,
        libraryName: String,
        symbolPrefix: String
    ) {
        self.targetName = targetName
        self.moduleName = moduleName
        self.artifactName = artifactName
        self.libraryName = libraryName
        self.symbolPrefix = symbolPrefix
    }

    private static func isPortableTargetName(_ value: String) -> Bool {
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
