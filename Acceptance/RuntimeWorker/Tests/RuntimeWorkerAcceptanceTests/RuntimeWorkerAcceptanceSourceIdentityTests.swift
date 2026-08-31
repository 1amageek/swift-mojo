import Foundation
import Testing

@testable import RuntimeWorkerAcceptance
@testable import RuntimeWorkerAcceptanceSourceIdentity

@Suite("Runtime worker acceptance source identity")
struct RuntimeWorkerAcceptanceSourceIdentityTests {
    private let verifier =
        FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()

    @Test(.timeLimit(.minutes(1)))
    func canonicalFramingIsStableAcrossCreationOrder() throws {
        let forward = try SourceIdentityFixture(
            paths: RuntimeWorkerAcceptanceSourceIdentity.filePaths
        )
        defer { forward.remove() }
        let reverse = try SourceIdentityFixture(
            paths: RuntimeWorkerAcceptanceSourceIdentity.filePaths.reversed()
        )
        defer { reverse.remove() }

        let first = try verifier.sourceIdentity(at: forward.root)
        let second = try verifier.sourceIdentity(at: reverse.root)
        let expectedInventory = RuntimeWorkerAcceptanceSourceIdentity.filePaths
            .sorted(by: utf8PathPrecedes)

        #expect(
            RuntimeWorkerAcceptanceSourceIdentity.filePaths
                == expectedInventory
        )
        #expect(first == second)
        #expect(
            first.algorithm
                == RuntimeWorkerAcceptanceSourceIdentity.algorithmValue
        )
        #expect(first.inventory == expectedInventory)
        #expect(first.files.map(\.path) == expectedInventory)
        #expect(
            first.digest
                == "8f3cb8663014a4e3bc83de36d970f3cc6a4305054d9331e77129fbff22d1b4c7"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func intermediateAncestorSymlinkIsRejected() throws {
        let fixture = try SourceIdentityFixture()
        defer { fixture.remove() }
        let external = try SourceIdentityFixture()
        defer { external.remove() }
        let ancestorPath = "Acceptance/RuntimeWorker/Sources"
        try fixture.replaceWithSymbolicLink(
            path: ancestorPath,
            destination: external.url(for: ancestorPath).path
        )

        expectSourceIdentityError(.symbolicLink(ancestorPath)) {
            _ = try verifier.sourceIdentity(at: fixture.root)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func descriptorRejectsSameSizeInodeSwap() throws {
        let fixture = try SourceIdentityFixture()
        defer { fixture.remove() }
        let path = "Acceptance/RuntimeWorker/Package.swift"

        expectSourceIdentityError(.changedDuringRead(path)) {
            try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
                at: fixture.root
            ) { rootDescriptor, _ in
                try RuntimeWorkerAcceptancePOSIX.withRegularFile(
                    at: path,
                    from: rootDescriptor
                ) { _, _ in
                    try fixture.replaceWithSameSizeFile(path: path)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func descriptorRejectsSymlinkSwap() throws {
        let fixture = try SourceIdentityFixture()
        defer { fixture.remove() }
        let path = "Acceptance/RuntimeWorker/Package.swift"

        expectSourceIdentityError(.changedDuringRead(path)) {
            try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
                at: fixture.root
            ) { rootDescriptor, _ in
                try RuntimeWorkerAcceptancePOSIX.withRegularFile(
                    at: path,
                    from: rootDescriptor
                ) { _, _ in
                    try fixture.replaceWithSymbolicLinkToOriginal(path: path)
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func contentAndPathMutationsCannotReuseIdentity() throws {
        let contentFixture = try SourceIdentityFixture()
        defer { contentFixture.remove() }
        let before = try verifier.sourceIdentity(at: contentFixture.root)
        let changedPath = RuntimeWorkerAcceptanceSourceIdentity.filePaths[9]
        try contentFixture.append(Data("mutation".utf8), to: changedPath)
        let after = try verifier.sourceIdentity(at: contentFixture.root)

        #expect(after.digest != before.digest)
        #expect(
            after.files.first(where: { $0.path == changedPath })?.digest
                != before.files.first(where: { $0.path == changedPath })?.digest
        )

        let pathFixture = try SourceIdentityFixture()
        defer { pathFixture.remove() }
        let originalPath = "scripts/runtime-worker-acceptance.sh"
        let renamedPath = "scripts/runtime-worker-acceptance-renamed.sh"
        try pathFixture.move(from: originalPath, to: renamedPath)

        expectSourceIdentityError(.missingEntry(originalPath)) {
            _ = try verifier.sourceIdentity(at: pathFixture.root)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func closedInventoryRejectsMissingExtraAndSymlinkEntries() throws {
        let missingFixture = try SourceIdentityFixture()
        defer { missingFixture.remove() }
        let missingPath = "Acceptance/RuntimeWorker/Package.swift"
        try missingFixture.remove(path: missingPath)
        expectSourceIdentityError(.missingEntry(missingPath)) {
            _ = try verifier.sourceIdentity(at: missingFixture.root)
        }

        let extraFixture = try SourceIdentityFixture()
        defer { extraFixture.remove() }
        let extraPath = "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/Unexpected.swift"
        try extraFixture.write(Data("unexpected".utf8), to: extraPath)
        expectSourceIdentityError(.unexpectedEntry(extraPath)) {
            _ = try verifier.sourceIdentity(at: extraFixture.root)
        }

        let symlinkFixture = try SourceIdentityFixture()
        defer { symlinkFixture.remove() }
        let linkPath =
            "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/UnexpectedLink.swift"
        try symlinkFixture.createSymbolicLink(
            at: linkPath,
            destination: symlinkFixture.url(
                for:
                    "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceContract.swift"
            ).path
        )
        expectSourceIdentityError(.symbolicLink(linkPath)) {
            _ = try verifier.sourceIdentity(at: symlinkFixture.root)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func regularFileAndByteBoundsFailClosed() throws {
        let nonRegularFixture = try SourceIdentityFixture()
        defer { nonRegularFixture.remove() }
        let nonRegularPath = "Acceptance/RuntimeWorker/Package.swift"
        try nonRegularFixture.replaceWithDirectory(path: nonRegularPath)
        expectSourceIdentityError(.nonRegularEntry(nonRegularPath)) {
            _ = try verifier.sourceIdentity(at: nonRegularFixture.root)
        }

        let fileBoundFixture = try SourceIdentityFixture()
        defer { fileBoundFixture.remove() }
        let oversizedPath = RuntimeWorkerAcceptanceSourceIdentity.filePaths[0]
        try fileBoundFixture.write(
            Data(
                repeating: 0,
                count: RuntimeWorkerAcceptanceSourceIdentity
                    .maximumFileByteCount + 1
            ),
            to: oversizedPath
        )
        expectSourceIdentityError(
            .fileTooLarge(
                path: oversizedPath,
                maximumByteCount: RuntimeWorkerAcceptanceSourceIdentity
                    .maximumFileByteCount
            )
        ) {
            _ = try verifier.sourceIdentity(at: fileBoundFixture.root)
        }

        let totalBoundFixture = try SourceIdentityFixture()
        defer { totalBoundFixture.remove() }
        for path in RuntimeWorkerAcceptanceSourceIdentity.filePaths.prefix(4) {
            try totalBoundFixture.write(
                Data(
                    repeating: 1,
                    count: RuntimeWorkerAcceptanceSourceIdentity
                        .maximumFileByteCount
                ),
                to: path
            )
        }
        expectSourceIdentityError(
            .totalTooLarge(
                maximumByteCount: RuntimeWorkerAcceptanceSourceIdentity
                    .maximumTotalByteCount
            )
        ) {
            _ = try verifier.sourceIdentity(at: totalBoundFixture.root)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func controllerRejectsContractMismatchAndExecutionMutation() throws {
        let fixture = try SourceIdentityFixture()
        defer { fixture.remove() }
        let identity = try verifier.sourceIdentity(at: fixture.root)

        do {
            try RuntimeWorkerAcceptanceController
                .requireCanonicalSourceIdentity(
                    identity,
                    expectedDigest: String(repeating: "0", count: 64)
                )
            Issue.record("a mismatched source digest was accepted")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            #expect(
                error
                    == .sourceIdentityMismatch(
                        expected: String(repeating: "0", count: 64),
                        actual: identity.digest
                    )
            )
        }

        let wrongAlgorithm = RuntimeWorkerAcceptanceSourceIdentity(
            algorithm: "sha256-unknown-v1",
            inventory: identity.inventory,
            files: identity.files,
            totalByteCount: identity.totalByteCount,
            digest: identity.digest
        )
        do {
            try RuntimeWorkerAcceptanceController
                .requireCanonicalSourceIdentity(
                    wrongAlgorithm,
                    expectedDigest: identity.digest
                )
            Issue.record("a mismatched source algorithm was accepted")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            #expect(error == .sourceIdentityContractMismatch("algorithm"))
        }

        let changed = RuntimeWorkerAcceptanceSourceIdentity(
            algorithm: identity.algorithm,
            inventory: identity.inventory,
            files: identity.files,
            totalByteCount: identity.totalByteCount,
            digest: String(repeating: "f", count: 64)
        )
        do {
            try RuntimeWorkerAcceptanceController.requireStableSourceIdentity(
                before: identity,
                after: changed
            )
            Issue.record("an execution-time source mutation was accepted")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            #expect(
                error
                    == .sourceIdentityChanged(
                        before: identity.digest,
                        after: changed.digest
                    )
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func actualRepositoryMatchesTheClosedInventory() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let identity = try verifier.sourceIdentity(at: repositoryRoot)

        #expect(identity.inventory.count == 33)
        #expect(identity.files.count == identity.inventory.count)
        #expect(identity.totalByteCount > 0)
        #expect(identity.digest.utf8.count == 64)
        try RuntimeWorkerAcceptanceController.requireCanonicalSourceIdentity(
            identity,
            expectedDigest: identity.digest
        )
    }
}

private final class SourceIdentityFixture {
    let root: URL
    private let fileManager = FileManager.default

    init(
        paths: some Sequence<String> =
            RuntimeWorkerAcceptanceSourceIdentity.filePaths
    ) throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "runtime-worker-source-identity-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        for path in paths {
            try write(Self.contents(for: path), to: path)
        }
    }

    func url(for path: String) -> URL {
        root.appendingPathComponent(path)
    }

    func append(_ data: Data, to path: String) throws {
        var contents = try Data(contentsOf: url(for: path))
        contents.append(data)
        try contents.write(to: url(for: path))
    }

    func write(_ data: Data, to path: String) throws {
        let destination = url(for: path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination)
    }

    func move(from sourcePath: String, to destinationPath: String) throws {
        try fileManager.moveItem(
            at: url(for: sourcePath),
            to: url(for: destinationPath)
        )
    }

    func remove(path: String) throws {
        try fileManager.removeItem(at: url(for: path))
    }

    func createSymbolicLink(at path: String, destination: String) throws {
        try fileManager.createSymbolicLink(
            atPath: url(for: path).path,
            withDestinationPath: destination
        )
    }

    func replaceWithDirectory(path: String) throws {
        try remove(path: path)
        try fileManager.createDirectory(
            at: url(for: path),
            withIntermediateDirectories: false
        )
    }

    func replaceWithSymbolicLink(
        path: String,
        destination: String
    ) throws {
        try remove(path: path)
        try createSymbolicLink(at: path, destination: destination)
    }

    func replaceWithSameSizeFile(path: String) throws {
        let original = try Data(contentsOf: url(for: path))
        let retainedPath = path + ".retained-" + UUID().uuidString
        try move(from: path, to: retainedPath)
        try write(Data(repeating: 0x78, count: original.count), to: path)
    }

    func replaceWithSymbolicLinkToOriginal(path: String) throws {
        let retainedPath = path + ".retained-" + UUID().uuidString
        try move(from: path, to: retainedPath)
        try createSymbolicLink(
            at: path,
            destination: url(for: retainedPath).path
        )
    }

    func remove() {
        do {
            try fileManager.removeItem(at: root)
        } catch {
            Issue.record("source identity fixture cleanup failed: \(error)")
        }
    }

    private static func contents(for path: String) -> Data {
        Data("fixture:\(path)\n".utf8)
    }
}

private func utf8PathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func expectSourceIdentityError(
    _ expected: RuntimeWorkerAcceptanceSourceIdentityError,
    operation: () throws -> Void
) {
    do {
        try operation()
        Issue.record("source identity verification unexpectedly succeeded")
    } catch let error as RuntimeWorkerAcceptanceSourceIdentityError {
        #expect(error == expected)
    } catch {
        Issue.record("unexpected source identity error: \(error)")
    }
}
