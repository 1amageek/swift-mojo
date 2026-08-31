#if canImport(CryptoKit)
    import CryptoKit
#elseif canImport(Crypto)
    import Crypto
#else
    #error("Runtime worker acceptance source identity requires CryptoKit or Crypto")
#endif
import Foundation

public struct FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier:
    RuntimeWorkerAcceptanceSourceIdentityVerifying,
    Sendable
{
    private struct TreeObservation: Equatable {
        var entries: [String: RuntimeWorkerAcceptancePOSIX.FileState] = [:]
        var files: Set<String> = []
    }

    private struct ReadResult {
        let byteCount: Int
        let digest: String
    }

    private static let readChunkByteCount = 64 * 1024
    private static let ownedDirectoryPaths: [String] = [
        "Acceptance/RuntimeWorker/Fixtures/Consumer",
        "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel",
        "Acceptance/RuntimeWorker/Mojo",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceRunner",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceRunner",
    ]

    public init() {}

    public func sourceIdentity(
        at repositoryRoot: URL
    ) throws -> RuntimeWorkerAcceptanceSourceIdentity {
        let expectedFiles = Set(RuntimeWorkerAcceptanceSourceIdentity.filePaths)
        guard
            expectedFiles.count
                == RuntimeWorkerAcceptanceSourceIdentity.filePaths.count
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidPath(
                "duplicate closed-inventory path"
            )
        }
        for path in RuntimeWorkerAcceptanceSourceIdentity.filePaths {
            try Self.validatePath(path)
        }
        let expectedDirectories = Self.expectedDirectories(
            for: RuntimeWorkerAcceptanceSourceIdentity.filePaths
        )
        let sortedPaths = expectedFiles.sorted(by: Self.pathPrecedes)

        return try RuntimeWorkerAcceptancePOSIX.withRepositoryRoot(
            at: repositoryRoot
        ) { rootDescriptor, _ in
            let initialTree = try Self.closedTreeObservation(
                rootDescriptor: rootDescriptor,
                expectedFiles: expectedFiles,
                expectedDirectories: expectedDirectories
            )

            var aggregateHasher = SHA256()
            var totalByteCount = 0
            var records: [RuntimeWorkerAcceptanceSourceIdentity.FileRecord] = []
            records.reserveCapacity(sortedPaths.count)
            for path in sortedPaths {
                aggregateHasher.update(data: Data(path.utf8))
                aggregateHasher.update(data: Data([0]))
                let record = try Self.hashFile(
                    path,
                    rootDescriptor: rootDescriptor,
                    aggregateHasher: &aggregateHasher,
                    totalByteCount: &totalByteCount
                )
                aggregateHasher.update(data: Data([0]))
                records.append(record)
            }

            let finalTree = try Self.closedTreeObservation(
                rootDescriptor: rootDescriptor,
                expectedFiles: expectedFiles,
                expectedDirectories: expectedDirectories
            )
            guard initialTree == finalTree else {
                let changedPath =
                    Set(initialTree.entries.keys)
                    .union(finalTree.entries.keys)
                    .sorted(by: Self.pathPrecedes)
                    .first {
                        initialTree.entries[$0] != finalTree.entries[$0]
                    } ?? "closed source tree"
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(changedPath)
            }

            return RuntimeWorkerAcceptanceSourceIdentity(
                algorithm: RuntimeWorkerAcceptanceSourceIdentity.algorithmValue,
                inventory: sortedPaths,
                files: records,
                totalByteCount: totalByteCount,
                digest: Self.hex(aggregateHasher.finalize())
            )
        }
    }

    private static func closedTreeObservation(
        rootDescriptor: Int32,
        expectedFiles: Set<String>,
        expectedDirectories: Set<String>
    ) throws -> TreeObservation {
        var observation = TreeObservation()
        for directory in ownedDirectoryPaths {
            guard expectedDirectories.contains(directory) else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .unexpectedEntry(directory)
            }
            try RuntimeWorkerAcceptancePOSIX.withDirectory(
                at: directory,
                from: rootDescriptor
            ) { descriptor, state in
                try record(
                    state,
                    path: directory,
                    observation: &observation
                )
                try visitDirectory(
                    descriptor: descriptor,
                    relativePath: directory,
                    expectedFiles: expectedFiles,
                    expectedDirectories: expectedDirectories,
                    observation: &observation
                )
            }
        }

        for path in RuntimeWorkerAcceptanceSourceIdentity.filePaths
        where !isInsideOwnedDirectory(path) {
            try RuntimeWorkerAcceptancePOSIX.withRegularFile(
                at: path,
                from: rootDescriptor
            ) { _, state in
                try record(state, path: path, observation: &observation)
                observation.files.insert(path)
            }
        }

        let missing = expectedFiles.subtracting(observation.files).sorted(
            by: pathPrecedes
        )
        if let path = missing.first {
            throw RuntimeWorkerAcceptanceSourceIdentityError.missingEntry(path)
        }
        let unexpected = observation.files.subtracting(expectedFiles).sorted(
            by: pathPrecedes
        )
        if let path = unexpected.first {
            throw RuntimeWorkerAcceptanceSourceIdentityError.unexpectedEntry(
                path
            )
        }
        return observation
    }

    private static func visitDirectory(
        descriptor: Int32,
        relativePath: String,
        expectedFiles: Set<String>,
        expectedDirectories: Set<String>,
        observation: inout TreeObservation
    ) throws {
        let names = try RuntimeWorkerAcceptancePOSIX.directoryEntryNames(
            descriptor: descriptor,
            path: relativePath
        )
        for name in names {
            let childPath = relativePath + "/" + name
            try validatePath(childPath)
            let state = try RuntimeWorkerAcceptancePOSIX.stateAt(
                name,
                displayPath: childPath,
                parentDescriptor: descriptor
            )
            switch state.kind {
            case .symbolicLink:
                throw RuntimeWorkerAcceptanceSourceIdentityError.symbolicLink(
                    childPath
                )
            case .directory:
                guard expectedDirectories.contains(childPath) else {
                    throw
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .unexpectedEntry(childPath)
                }
                try RuntimeWorkerAcceptancePOSIX.withChildDirectory(
                    named: name,
                    displayPath: childPath,
                    from: descriptor
                ) { childDescriptor, openedState in
                    try record(
                        openedState,
                        path: childPath,
                        observation: &observation
                    )
                    try visitDirectory(
                        descriptor: childDescriptor,
                        relativePath: childPath,
                        expectedFiles: expectedFiles,
                        expectedDirectories: expectedDirectories,
                        observation: &observation
                    )
                }
            case .regular:
                guard expectedFiles.contains(childPath) else {
                    throw
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .unexpectedEntry(childPath)
                }
                try record(
                    state,
                    path: childPath,
                    observation: &observation
                )
                observation.files.insert(childPath)
            case .other:
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .nonRegularEntry(childPath)
            }
        }
    }

    private static func record(
        _ state: RuntimeWorkerAcceptancePOSIX.FileState,
        path: String,
        observation: inout TreeObservation
    ) throws {
        if let existing = observation.entries[path], existing != state {
            throw RuntimeWorkerAcceptanceSourceIdentityError.changedDuringRead(
                path
            )
        }
        observation.entries[path] = state
    }

    private static func hashFile(
        _ path: String,
        rootDescriptor: Int32,
        aggregateHasher: inout SHA256,
        totalByteCount: inout Int
    ) throws -> RuntimeWorkerAcceptanceSourceIdentity.FileRecord {
        try RuntimeWorkerAcceptancePOSIX.withRegularFile(
            at: path,
            from: rootDescriptor
        ) { descriptor, state in
            guard state.byteCount >= 0,
                state.byteCount <= Int64(Int.max)
            else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                    path: path,
                    detail: "file size is unavailable"
                )
            }
            let declaredByteCount = Int(state.byteCount)
            guard
                declaredByteCount
                    <= RuntimeWorkerAcceptanceSourceIdentity
                    .maximumFileByteCount
            else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.fileTooLarge(
                    path: path,
                    maximumByteCount:
                        RuntimeWorkerAcceptanceSourceIdentity
                        .maximumFileByteCount
                )
            }
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

            let first = try readFile(
                descriptor: descriptor,
                path: path,
                maximumFileByteCount:
                    RuntimeWorkerAcceptanceSourceIdentity.maximumFileByteCount,
                maximumAggregateByteCount:
                    RuntimeWorkerAcceptanceSourceIdentity
                    .maximumTotalByteCount - totalByteCount,
                aggregateHasher: &aggregateHasher
            )
            totalByteCount += first.byteCount
            guard first.byteCount == declaredByteCount else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(path)
            }

            try RuntimeWorkerAcceptancePOSIX.rewind(
                descriptor: descriptor,
                path: path
            )
            var unusedAggregate: SHA256? = nil
            let second = try readFile(
                descriptor: descriptor,
                path: path,
                maximumFileByteCount:
                    RuntimeWorkerAcceptanceSourceIdentity.maximumFileByteCount,
                maximumAggregateByteCount: nil,
                aggregateHasher: &unusedAggregate
            )
            guard first.byteCount == second.byteCount,
                first.digest == second.digest
            else {
                throw
                    RuntimeWorkerAcceptanceSourceIdentityError
                    .changedDuringRead(path)
            }

            return RuntimeWorkerAcceptanceSourceIdentity.FileRecord(
                path: path,
                byteCount: first.byteCount,
                digest: first.digest
            )
        }
    }

    private static func readFile(
        descriptor: Int32,
        path: String,
        maximumFileByteCount: Int,
        maximumAggregateByteCount: Int?,
        aggregateHasher: inout SHA256
    ) throws -> ReadResult {
        var optionalHasher: SHA256? = aggregateHasher
        let result = try readFile(
            descriptor: descriptor,
            path: path,
            maximumFileByteCount: maximumFileByteCount,
            maximumAggregateByteCount: maximumAggregateByteCount,
            aggregateHasher: &optionalHasher
        )
        guard let optionalHasher else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.unreadableFile(
                path: path,
                detail: "aggregate hasher state is unavailable"
            )
        }
        aggregateHasher = optionalHasher
        return result
    }

    private static func readFile(
        descriptor: Int32,
        path: String,
        maximumFileByteCount: Int,
        maximumAggregateByteCount: Int?,
        aggregateHasher: inout SHA256?
    ) throws -> ReadResult {
        var fileHasher = SHA256()
        var observedByteCount = 0
        var buffer = [UInt8](
            repeating: 0,
            count: readChunkByteCount
        )
        while true {
            let count = try buffer.withUnsafeMutableBytes {
                try RuntimeWorkerAcceptancePOSIX.read(
                    descriptor: descriptor,
                    into: $0,
                    path: path
                )
            }
            guard count != 0 else { break }
            guard count <= maximumFileByteCount - observedByteCount else {
                throw RuntimeWorkerAcceptanceSourceIdentityError.fileTooLarge(
                    path: path,
                    maximumByteCount: maximumFileByteCount
                )
            }
            if let maximumAggregateByteCount {
                guard
                    count
                        <= maximumAggregateByteCount - observedByteCount
                else {
                    throw
                        RuntimeWorkerAcceptanceSourceIdentityError
                        .totalTooLarge(
                            maximumByteCount:
                                RuntimeWorkerAcceptanceSourceIdentity
                                .maximumTotalByteCount
                        )
                }
            }
            observedByteCount += count
            let data = buffer.withUnsafeBytes {
                Data($0.prefix(count))
            }
            fileHasher.update(data: data)
            aggregateHasher?.update(data: data)
        }
        return ReadResult(
            byteCount: observedByteCount,
            digest: hex(fileHasher.finalize())
        )
    }

    private static func expectedDirectories(
        for filePaths: [String]
    ) -> Set<String> {
        var directories = Set<String>()
        for path in filePaths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for count in 1..<components.count {
                directories.insert(
                    components.prefix(count).joined(separator: "/")
                )
            }
        }
        return directories
    }

    private static func isInsideOwnedDirectory(_ path: String) -> Bool {
        ownedDirectoryPaths.contains { path.hasPrefix($0 + "/") }
    }

    private static func validatePath(_ path: String) throws {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.utf8.contains(0),
            path.utf8.allSatisfy({ $0 < 128 }),
            components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw RuntimeWorkerAcceptanceSourceIdentityError.invalidPath(path)
        }
    }

    private static func pathPrecedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static func hex<Digest: Sequence>(_ digest: Digest) -> String
    where Digest.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
