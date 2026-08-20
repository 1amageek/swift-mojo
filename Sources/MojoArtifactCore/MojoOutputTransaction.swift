import Foundation

package struct MojoOutputTransaction: Sendable {
    package struct ExclusiveAccess: Sendable {
        fileprivate let outputURL: URL

        fileprivate init(outputURL: URL) {
            self.outputURL = outputURL.standardizedFileURL
        }
    }

    package static let markerName = ".swift-mojo-generated"
    package static let markerContents = Data(
        "swift-mojo-generated-output-v1\n".utf8
    )

    private let outputLock: MojoOutputLock

    package init(outputLock: MojoOutputLock = MojoOutputLock()) {
        self.outputLock = outputLock
    }

    package func withExclusiveAccess<Result>(
        to outputURL: URL,
        _ body: (ExclusiveAccess) throws -> Result
    ) throws -> Result {
        try outputLock.withLock(for: outputURL) {
            try body(ExclusiveAccess(outputURL: outputURL))
        }
    }

    package func isManaged(_ outputURL: URL) -> Bool {
        do {
            let contents = try Data(
                contentsOf: outputURL.appendingPathComponent(Self.markerName)
            )
            return contents == Self.markerContents
        } catch {
            return false
        }
    }

    package func makeStagingDirectory(for outputURL: URL) throws -> URL {
        let parent = outputURL.deletingLastPathComponent()
        guard outputURL.path != "/",
              outputURL.standardizedFileURL != parent.standardizedFileURL else {
            throw MojoArtifactError.invalidArguments(
                "The generated output directory must be a specific child directory"
            )
        }
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        let staging = parent.appendingPathComponent(
            ".\(outputURL.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: false
        )
        try Self.markerContents.write(
            to: staging.appendingPathComponent(Self.markerName)
        )
        return staging
    }

    package func commit(
        stagingURL: URL,
        outputURL: URL,
        access: ExclusiveAccess
    ) throws {
        guard access.outputURL == outputURL.standardizedFileURL else {
            throw MojoArtifactError.outputLockScopeMismatch(
                expected: access.outputURL.path,
                actual: outputURL.standardizedFileURL.path
            )
        }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path),
           !isManaged(outputURL) {
            throw MojoArtifactError.unmanagedOutputDirectory(outputURL.path)
        }

        guard fileManager.fileExists(atPath: outputURL.path) else {
            try fileManager.moveItem(at: stagingURL, to: outputURL)
            return
        }

        let backupURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.lastPathComponent).backup-\(UUID().uuidString)",
                isDirectory: true
            )
        try fileManager.moveItem(at: outputURL, to: backupURL)
        do {
            try fileManager.moveItem(at: stagingURL, to: outputURL)
            try fileManager.removeItem(at: backupURL)
        } catch {
            let primaryError = error
            var recoveryFailures: [String] = []
            if fileManager.fileExists(atPath: outputURL.path) {
                do {
                    try fileManager.removeItem(at: outputURL)
                } catch {
                    recoveryFailures.append("remove partial output: \(error)")
                }
            }
            if fileManager.fileExists(atPath: backupURL.path) {
                do {
                    try fileManager.moveItem(at: backupURL, to: outputURL)
                } catch {
                    recoveryFailures.append("restore prior output: \(error)")
                }
            }
            guard recoveryFailures.isEmpty else {
                throw MojoArtifactError.commandFailed(
                    command: "restore generated output transaction",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); recovery failures: \(recoveryFailures.joined(separator: "; "))"
                )
            }
            throw primaryError
        }
    }
}
