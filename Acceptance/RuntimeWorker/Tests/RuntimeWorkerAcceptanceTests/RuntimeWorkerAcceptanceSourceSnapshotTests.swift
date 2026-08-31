import Foundation
import Synchronization
import Testing

@testable import RuntimeWorkerAcceptance

@Suite("Runtime worker acceptance source snapshot")
struct RuntimeWorkerAcceptanceSourceSnapshotTests {
    @Test(.timeLimit(.minutes(1)))
    func materializesOnlyCanonicalReadOnlySource() throws {
        let fixture = try SnapshotSourceFixture()
        defer { fixture.remove() }
        let destinationParent = try SnapshotDestinationParent()
        defer { destinationParent.remove() }
        let destination = destinationParent.root.appendingPathComponent(
            "snapshot",
            isDirectory: true
        )

        let snapshot = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter()
            .materializeVerifiedSnapshot(
                from: fixture.root,
                at: destination
            )
        let verifier =
            FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()
        let sourceIdentity = try verifier.sourceIdentity(at: fixture.root)

        #expect(snapshot.rootURL == destination.standardizedFileURL)
        #expect(snapshot.identity == sourceIdentity)
        #expect(
            snapshot.executionScriptContents
                == Data(
                    "snapshot:\(RuntimeWorkerAcceptanceSourceIdentity.executionScriptPath)\n"
                        .utf8
                )
        )
        #expect(try permissions(at: destination) == 0o555)
        #expect(
            try permissions(
                at: destination.appendingPathComponent(
                    "Acceptance/RuntimeWorker/Package.swift"
                )
            ) == 0o444
        )
        #expect(
            try permissions(
                at: destination.appendingPathComponent(
                    "scripts/runtime-worker-acceptance.sh"
                )
            ) == 0o555
        )

        do {
            try Data("mutation".utf8).write(
                to: destination.appendingPathComponent(
                    "Acceptance/RuntimeWorker/Package.swift"
                )
            )
            Issue.record("read-only snapshot file accepted a write")
        } catch {
            #expect(true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsExistingDestinationWithoutRemovingIt() throws {
        let fixture = try SnapshotSourceFixture()
        defer { fixture.remove() }
        let destinationParent = try SnapshotDestinationParent()
        defer { destinationParent.remove() }
        let destination = destinationParent.root.appendingPathComponent(
            "existing",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: false
        )

        expectSnapshotError(.destinationExists(destination.path)) {
            _ = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter()
                .materializeVerifiedSnapshot(
                    from: fixture.root,
                    at: destination
                )
        }
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceMismatchRemovesThePartialSnapshot() throws {
        let fixture = try SnapshotSourceFixture()
        defer { fixture.remove() }
        let destinationParent = try SnapshotDestinationParent()
        defer { destinationParent.remove() }
        let destination = destinationParent.root.appendingPathComponent(
            "mismatch",
            isDirectory: true
        )
        let verifier =
            FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()
        let identity = try verifier.sourceIdentity(at: fixture.root)
        let changedIdentity = RuntimeWorkerAcceptanceSourceIdentity(
            algorithm: identity.algorithm,
            inventory: identity.inventory,
            files: identity.files,
            totalByteCount: identity.totalByteCount,
            digest: String(repeating: "f", count: 64)
        )
        let sequence = SequencedSourceIdentityVerifier([
            identity,
            identity,
            changedIdentity,
        ])

        expectSnapshotError(.snapshotMismatch) {
            _ = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter(
                verifier: sequence
            ).materializeVerifiedSnapshot(
                from: fixture.root,
                at: destination
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class SequencedSourceIdentityVerifier:
    RuntimeWorkerAcceptanceSourceIdentityVerifying,
    Sendable
{
    private let state: Mutex<[RuntimeWorkerAcceptanceSourceIdentity]>

    init(_ identities: [RuntimeWorkerAcceptanceSourceIdentity]) {
        self.state = Mutex(identities)
    }

    func sourceIdentity(
        at repositoryRoot: URL
    ) throws -> RuntimeWorkerAcceptanceSourceIdentity {
        try state.withLock { identities in
            guard !identities.isEmpty else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                    repositoryRoot.path
                )
            }
            return identities.removeFirst()
        }
    }
}

private final class SnapshotSourceFixture {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "runtime-worker-source-snapshot-input-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        for path in RuntimeWorkerAcceptanceSourceIdentity.filePaths {
            let destination = root.appendingPathComponent(path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("snapshot:\(path)\n".utf8).write(to: destination)
        }
    }

    func remove() {
        removeSnapshotTree(at: root)
    }
}

private final class SnapshotDestinationParent {
    let root: URL
    private let fileManager = FileManager.default

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "runtime-worker-source-snapshot-output-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        removeSnapshotTree(at: root)
    }
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private func removeSnapshotTree(at root: URL) {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: root.path) else {
        return
    }
    if let enumerator = fileManager.enumerator(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [],
        errorHandler: nil
    ) {
        var directories = [root]
        while let item = enumerator.nextObject() as? URL {
            do {
                let values = try item.resourceValues(
                    forKeys: [.isDirectoryKey]
                )
                if values.isDirectory == true {
                    directories.append(item)
                }
            } catch {
                Issue.record("snapshot cleanup inspection failed: \(error)")
            }
        }
        for directory in directories {
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } catch {
                Issue.record("snapshot cleanup permission failed: \(error)")
            }
        }
    }
    do {
        try fileManager.removeItem(at: root)
    } catch {
        Issue.record("snapshot fixture cleanup failed: \(error)")
    }
}

private func expectSnapshotError(
    _ expected: RuntimeWorkerAcceptanceSourceIdentityError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("source snapshot operation unexpectedly succeeded")
    } catch let error as RuntimeWorkerAcceptanceSourceIdentityError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected source snapshot error: \(error)")
    }
}
