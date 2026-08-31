#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(Crypto)
    import Crypto
#else
    #error("Runtime worker acceptance source identity requires CryptoKit or Crypto")
#endif
import Foundation

public struct FileSystemRuntimeWorkerAcceptanceSourceSnapshotter:
    RuntimeWorkerAcceptanceSourceSnapshotting,
    Sendable
{
    private static let readChunkByteCount = 64 * 1024
    private let verifier: any RuntimeWorkerAcceptanceSourceIdentityVerifying

    public init() {
        self.verifier = FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()
    }

    init(
        verifier: any RuntimeWorkerAcceptanceSourceIdentityVerifying
    ) {
        self.verifier = verifier
    }

    public func materializeVerifiedSnapshot(
        from sourceRoot: URL,
        at destinationRoot: URL
    ) throws -> RuntimeWorkerAcceptanceSourceSnapshot {
        let source = sourceRoot.standardizedFileURL
        let destination = destinationRoot.standardizedFileURL
        try validateDestination(destination, source: source)

        let identityBefore = try verifier.sourceIdentity(at: source)
        var destinationCreated = false
        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            destinationCreated = true
            try copyInventory(
                identityBefore.inventory,
                source: source,
                destination: destination
            )

            let snapshotIdentity = try verifier.sourceIdentity(at: destination)
            let sourceIdentityAfter = try verifier.sourceIdentity(at: source)
            guard identityBefore == snapshotIdentity,
                identityBefore == sourceIdentityAfter
            else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.snapshotMismatch
            }

            try makeReadOnly(
                identityBefore.inventory,
                destination: destination
            )
            let finalSnapshotIdentity = try verifier.sourceIdentity(
                at: destination
            )
            guard finalSnapshotIdentity == identityBefore else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.snapshotMismatch
            }
            let executionScriptContents = try verifiedExecutionScript(
                at: destination,
                identity: finalSnapshotIdentity
            )

            return RuntimeWorkerAcceptanceSourceSnapshot(
                rootURL: destination,
                identity: finalSnapshotIdentity,
                executionScriptContents: executionScriptContents
            )
        } catch {
            guard destinationCreated else {
                throw error
            }
            do {
                try restoreWritableDirectories(
                    destination,
                    inventory: identityBefore.inventory
                )
                try FileManager.default.removeItem(at: destination)
            } catch let cleanupError {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .snapshotCleanupFailed(
                        path: destination.path,
                        detail: String(describing: cleanupError)
                    )
            }
            throw error
        }
    }

    private func validateDestination(
        _ destination: URL,
        source: URL
    ) throws {
        guard destination.isFileURL, source.isFileURL,
            !isContained(destination, by: source),
            destination.path != source.path
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                destination.path
            )
        }

        let parent = destination.deletingLastPathComponent()
        let values: URLResourceValues
        do {
            values = try parent.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        } catch {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                parent.path
            )
        }
        guard values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                parent.path
            )
        }
        let parentAttributes: [FileAttributeKey: Any]
        do {
            parentAttributes = try FileManager.default.attributesOfItem(
                atPath: parent.path
            )
        } catch {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                parent.path
            )
        }
        guard let parentPermissions = (parentAttributes[.posixPermissions] as? NSNumber)?.intValue,
            parentPermissions & 0o077 == 0
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidRoot(
                parent.path
            )
        }

        do {
            try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
                at: parent
            ) { parentDescriptor, _ in
                _ = try RuntimeWorkerAcceptancePOSIX.stateAt(
                    destination.lastPathComponent,
                    displayPath: destination.path,
                    parentDescriptor: parentDescriptor
                )
            }
            throw RuntimeWorkerAcceptanceSourceIdentityError.destinationExists(
                destination.path
            )
        } catch RuntimeWorkerAcceptanceSourceIdentityError.missingEntry(
            let path
        ) where path == destination.path {
            return
        }
    }

    private func copyInventory(
        _ inventory: [String],
        source: URL,
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        var totalByteCount = 0
        try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
            at: source
        ) { sourceDescriptor, _ in
            for relativePath in inventory {
                let destinationFile = destination.appendingPathComponent(
                    relativePath
                )
                let parent = destinationFile.deletingLastPathComponent()
                try fileManager.createDirectory(
                    at: parent,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                let contents = try snapshotContents(
                    at: relativePath,
                    rootDescriptor: sourceDescriptor,
                    totalByteCount: &totalByteCount
                )
                do {
                    try contents.write(
                        to: destinationFile,
                        options: [.withoutOverwriting]
                    )
                } catch {
                    throw
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .snapshotMaterializationFailed(
                            path: relativePath,
                            detail: String(describing: error)
                        )
                }
            }
        }
    }

    private func snapshotContents(
        at relativePath: String,
        rootDescriptor: Int32,
        totalByteCount: inout Int
    ) throws -> Data {
        try RuntimeWorkerAcceptancePOSIX.withRegularFile(
            at: relativePath,
            from: rootDescriptor
        ) { descriptor, state in
            guard state.byteCount >= 0,
                state.byteCount
                    <= Int64(
                        RuntimeWorkerAcceptanceSourceIdentity.maximumFileByteCount
                    )
            else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.fileTooLarge(
                    path: relativePath,
                    maximumByteCount:
                        RuntimeWorkerAcceptanceSourceIdentity
                        .maximumFileByteCount
                )
            }
            let declaredByteCount = Int(state.byteCount)
            guard
                declaredByteCount
                    <= RuntimeWorkerAcceptanceSourceIdentity
                    .maximumTotalByteCount - totalByteCount
            else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.totalTooLarge(
                    maximumByteCount:
                        RuntimeWorkerAcceptanceSourceIdentity
                        .maximumTotalByteCount
                )
            }

            var contents = Data()
            contents.reserveCapacity(declaredByteCount)
            var buffer = [UInt8](
                repeating: 0,
                count: Self.readChunkByteCount
            )
            while true {
                let count = try buffer.withUnsafeMutableBytes {
                    try RuntimeWorkerAcceptancePOSIX.read(
                        descriptor: descriptor,
                        into: $0,
                        path: relativePath
                    )
                }
                guard count != 0 else { break }
                guard count <= declaredByteCount - contents.count else {
                    throw
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .changedDuringRead(relativePath)
                }
                try buffer.withUnsafeBytes { bytes in
                    guard
                        let baseAddress = bytes.bindMemory(to: UInt8.self)
                            .baseAddress
                    else {
                        throw
                            RuntimeWorkerAcceptanceSourceIdentityError
                            .changedDuringRead(relativePath)
                    }
                    contents.append(
                        baseAddress,
                        count: count
                    )
                }
            }
            guard contents.count == declaredByteCount else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(relativePath)
            }
            totalByteCount += contents.count
            return contents
        }
    }

    private func makeReadOnly(
        _ inventory: [String],
        destination: URL
    ) throws {
        let fileManager = FileManager.default
        for relativePath in inventory {
            let permissions: Int
            if relativePath == "scripts/runtime-worker-acceptance.sh"
                || relativePath == "scripts/command-timeout.sh"
            {
                permissions = 0o555
            } else {
                permissions = 0o444
            }
            let path = destination.appendingPathComponent(relativePath).path
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: path
                )
            } catch {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .snapshotPermissionFailed(
                        path: relativePath,
                        detail: String(describing: error)
                    )
            }
        }

        let directories = inventoryDirectories(inventory)
        for relativePath in directories.sorted(by: directoryDepthDescending) {
            let path = destination.appendingPathComponent(relativePath).path
            do {
                try fileManager.setAttributes(
                    [.posixPermissions: 0o555],
                    ofItemAtPath: path
                )
            } catch {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .snapshotPermissionFailed(
                        path: relativePath,
                        detail: String(describing: error)
                    )
            }
        }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: destination.path
            )
        } catch {
            throw
                RuntimeWorkerAcceptanceSourceIdentityError
                .snapshotPermissionFailed(
                    path: destination.path,
                    detail: String(describing: error)
                )
        }
    }

    private func verifiedExecutionScript(
        at snapshotRoot: URL,
        identity: RuntimeWorkerAcceptanceSourceIdentity
    ) throws -> Data {
        guard
            let record = identity.files.first(where: {
                $0.path
                    == RuntimeWorkerAcceptanceSourceIdentity.executionScriptPath
            })
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.snapshotMismatch
        }
        var observedTotalByteCount = 0
        let contents = try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
            at: snapshotRoot
        ) { rootDescriptor, _ in
            try snapshotContents(
                at: RuntimeWorkerAcceptanceSourceIdentity.executionScriptPath,
                rootDescriptor: rootDescriptor,
                totalByteCount: &observedTotalByteCount
            )
        }
        let digest = SHA256.hash(data: contents).map {
            String(format: "%02x", $0)
        }.joined()
        guard contents.count == record.byteCount,
            observedTotalByteCount == record.byteCount,
            digest == record.digest
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.snapshotMismatch
        }
        return contents
    }

    private func restoreWritableDirectories(
        _ destination: URL,
        inventory: [String]
    ) throws {
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return
        }
        let directories = inventoryDirectories(inventory).sorted()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: destination.path
        )
        for relativePath in directories {
            let directory = destination.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                continue
            }
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    private func inventoryDirectories(_ inventory: [String]) -> Set<String> {
        var directories: Set<String> = []
        for path in inventory {
            var components = path.split(separator: "/").map(String.init)
            _ = components.popLast()
            while !components.isEmpty {
                directories.insert(components.joined(separator: "/"))
                _ = components.popLast()
            }
        }
        return directories
    }

    private func directoryDepthDescending(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let lhsDepth = lhs.utf8.filter { $0 == 47 }.count
        let rhsDepth = rhs.utf8.filter { $0 == 47 }.count
        if lhsDepth == rhsDepth {
            return lhs > rhs
        }
        return lhsDepth > rhsDepth
    }

    private func isContained(_ candidate: URL, by root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }
}
