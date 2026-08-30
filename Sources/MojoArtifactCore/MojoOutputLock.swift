import Foundation
import MojoBindingCore
import MojoPOSIXSupport

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

        let descriptor: Int32
        do {
            descriptor = try MojoPOSIXSupport.openLockFile(
                path: lockURL.path
            )
        } catch {
            throw MojoArtifactError.outputLockFailed(
                path: lockURL.path,
                diagnostic: String(describing: error)
            )
        }

        do {
            try MojoPOSIXSupport.lockExclusive(descriptor)
        } catch {
            let primaryError = error
            do {
                try MojoPOSIXSupport.closeFile(descriptor)
            } catch let cleanupError {
                throw MojoArtifactError.outputLockFailed(
                    path: lockURL.path,
                    diagnostic: "Primary error: \(primaryError); descriptor cleanup error: \(cleanupError)"
                )
            }
            throw MojoArtifactError.outputLockFailed(
                path: lockURL.path,
                diagnostic: String(describing: primaryError)
            )
        }

        let bodyResult: Swift.Result<Result, any Error>
        do {
            bodyResult = .success(try body())
        } catch {
            bodyResult = .failure(error)
        }

        var cleanupDiagnostics: [String] = []
        do {
            try MojoPOSIXSupport.unlock(descriptor)
        } catch {
            cleanupDiagnostics.append("unlock: \(error)")
        }
        do {
            try MojoPOSIXSupport.closeFile(descriptor)
        } catch {
            cleanupDiagnostics.append("close: \(error)")
        }
        if !cleanupDiagnostics.isEmpty {
            let primaryDiagnostic: String
            switch bodyResult {
            case .success:
                primaryDiagnostic = "body succeeded"
            case .failure(let error):
                primaryDiagnostic = "body failed: \(error)"
            }
            throw MojoArtifactError.outputLockFailed(
                path: lockURL.path,
                diagnostic: "\(primaryDiagnostic); cleanup failed: \(cleanupDiagnostics.joined(separator: "; "))"
            )
        }
        return try bodyResult.get()
    }
}
