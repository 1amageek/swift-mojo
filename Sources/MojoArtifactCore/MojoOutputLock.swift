import Darwin
import Foundation
import MojoBindingCore

package struct MojoOutputLock: Sendable {
    package init() {}

    package func withLock<Result>(
        for outputURL: URL,
        _ body: () throws -> Result
    ) throws -> Result {
        let lockRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-mojo-output-locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: lockRoot,
            withIntermediateDirectories: true
        )
        let canonicalOutputPath = outputURL.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let lockURL = lockRoot.appendingPathComponent(
            MojoCanonicalDigest.hex(canonicalOutputPath) + ".lock"
        )

        // The C string is borrowed only for open(2) and never escapes this call.
        // This scope owns the returned descriptor and closes it exactly once.
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else {
            throw MojoArtifactError.outputLockFailed(
                path: lockURL.path,
                diagnostic: Self.systemErrorDescription()
            )
        }
        defer {
            _ = Darwin.flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }

        guard Darwin.flock(descriptor, LOCK_EX) == 0 else {
            throw MojoArtifactError.outputLockFailed(
                path: lockURL.path,
                diagnostic: Self.systemErrorDescription()
            )
        }
        return try body()
    }

    private static func systemErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}
