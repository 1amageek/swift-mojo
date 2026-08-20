import Foundation

package enum MojoRegularFile {
    package static func validate(at url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isSymbolicLink != true else {
            throw MojoArtifactError.symbolicLinkUnsupported(url.path)
        }
        guard values.isRegularFile == true else {
            throw MojoArtifactError.invalidArguments(
                "Expected a regular file at '\(url.path)'"
            )
        }
    }

    package static func isValid(at url: URL) -> Bool {
        do {
            try validate(at: url)
            return true
        } catch {
            return false
        }
    }
}
