import Foundation
import MojoArtifactCore
import Testing

@Suite("Artifact initialization safety")
struct MojoArtifactInitializerTests {
    @Test(.timeLimit(.minutes(1)))
    func preservesExistingPreparedArtifact() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let artifact = root.appendingPathComponent(
            MojoStaticABI.artifactName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: artifact,
            withIntermediateDirectories: true
        )
        try MojoOutputTransaction.markerContents.write(
            to: root.appendingPathComponent(MojoOutputTransaction.markerName)
        )
        let sentinel = artifact.appendingPathComponent("prepared-sentinel")
        try Data("prepared".utf8).write(to: sentinel)
        defer { removeArtifactFixture(root) }

        let disposition = try MojoArtifactInitializer().initialize(
            outputDirectoryURL: root
        )

        #expect(disposition == .alreadyInitialized)
        #expect(try Data(contentsOf: sentinel) == Data("prepared".utf8))
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnmanagedExistingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { removeArtifactFixture(root) }

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoArtifactInitializer().initialize(
                outputDirectoryURL: root
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsIncompleteManagedDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try MojoOutputTransaction.markerContents.write(
            to: root.appendingPathComponent(MojoOutputTransaction.markerName)
        )
        defer { removeArtifactFixture(root) }

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoArtifactInitializer().initialize(
                outputDirectoryURL: root
            )
        }
    }
}

private func removeArtifactFixture(_ root: URL) {
    do {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    } catch {
        Issue.record("Failed to remove artifact fixture: \(error)")
    }
}
