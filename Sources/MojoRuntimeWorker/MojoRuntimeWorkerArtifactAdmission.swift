import Crypto
import Foundation
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore
import Synchronization

package struct MojoRuntimeWorkerPrivateStage: Sendable {
    package let rootURL: URL
    package let bundleURL: URL
}

package final class MojoRuntimeWorkerAdmittedProcess: Sendable {
    package let verification: MojoRuntimeWorkerBundleVerification
    package let process: MojoPOSIXWorkerProcess
    package let stage: MojoRuntimeWorkerPrivateStage
    package let protocolLimits: MojoRuntimeProtocolLimits
    package let sequence: MojoRuntimeProtocolSequenceValidator
    package let startupDiagnostics: Data

    private let cleanupClaimed = Mutex(false)

    package init(
        verification: MojoRuntimeWorkerBundleVerification,
        process: MojoPOSIXWorkerProcess,
        stage: MojoRuntimeWorkerPrivateStage,
        protocolLimits: MojoRuntimeProtocolLimits,
        sequence: MojoRuntimeProtocolSequenceValidator,
        startupDiagnostics: Data
    ) {
        self.verification = verification
        self.process = process
        self.stage = stage
        self.protocolLimits = protocolLimits
        self.sequence = sequence
        self.startupDiagnostics = startupDiagnostics
    }

    package func claimTerminalCleanup() -> Bool {
        cleanupClaimed.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

package struct MojoRuntimeWorkerArtifactAdmission {
    package typealias CopyItem = (
        _ sourceURL: URL,
        _ destinationURL: URL
    ) throws -> Void
    package typealias Verify = (URL) throws
        -> MojoRuntimeWorkerBundleVerification
    package typealias Spawn = (
        _ executablePath: String,
        _ arguments: [String],
        _ environment: [String: String]?
    ) throws -> MojoPOSIXWorkerProcess
    package typealias ReadStartup = (
        _ process: MojoPOSIXWorkerProcess,
        _ verification: MojoRuntimeWorkerBundleVerification,
        _ timeout: Duration
    ) throws -> MojoRuntimeWorkerStartupResult
    package typealias ReadStartupAtDeadline = (
        _ process: MojoPOSIXWorkerProcess,
        _ verification: MojoRuntimeWorkerBundleVerification,
        _ deadline: ContinuousClock.Instant
    ) throws -> MojoRuntimeWorkerStartupResult
    package typealias MakeStageRoot = () -> URL
    package typealias RemoveItem = (_ url: URL) throws -> Void

    private let fileManager: FileManager
    private let copyItem: CopyItem
    private let verify: Verify
    private let spawn: Spawn
    private let readStartup: ReadStartup
    private let readStartupAtDeadline: ReadStartupAtDeadline?
    private let makeStageRoot: MakeStageRoot

    package init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        copyItem = { sourceURL, destinationURL in
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        verify = { bundleURL in
            try FileSystemMojoRuntimeWorkerBundleVerifier()
                .verifyWorkerBundle(at: bundleURL)
        }
        spawn = { executablePath, arguments, environment in
            try MojoPOSIXWorkerSupport.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment
            )
        }
        readStartup = { process, verification, timeout in
            try MojoRuntimeWorkerStartupReader.readReady(
                from: process,
                verification: verification,
                timeout: timeout
            )
        }
        readStartupAtDeadline = { process, verification, deadline in
            try MojoRuntimeWorkerStartupReader.readReady(
                from: process,
                verification: verification,
                deadline: deadline
            )
        }
        makeStageRoot = {
            Self.uniqueStageRoot(fileManager: fileManager)
        }
    }

    package init(
        fileManager: FileManager,
        copyItem: CopyItem? = nil,
        verify: @escaping Verify,
        spawn: @escaping Spawn,
        readStartup: @escaping ReadStartup,
        makeStageRoot: MakeStageRoot? = nil
    ) {
        self.fileManager = fileManager
        self.copyItem = copyItem ?? { sourceURL, destinationURL in
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        self.verify = verify
        self.spawn = spawn
        self.readStartup = readStartup
        self.readStartupAtDeadline = nil
        self.makeStageRoot = makeStageRoot ?? {
            Self.uniqueStageRoot(fileManager: fileManager)
            }
    }

    package init(
        fileManager: FileManager,
        copyItem: CopyItem? = nil,
        verify: @escaping Verify,
        spawn: @escaping Spawn,
        readStartupAtDeadline: @escaping ReadStartupAtDeadline,
        makeStageRoot: MakeStageRoot? = nil
    ) {
        self.fileManager = fileManager
        self.copyItem = copyItem ?? { sourceURL, destinationURL in
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
        self.verify = verify
        self.spawn = spawn
        self.readStartup = { process, verification, timeout in
            let clock = ContinuousClock()
            return try readStartupAtDeadline(
                process,
                verification,
                clock.now.advanced(by: timeout)
            )
        }
        self.readStartupAtDeadline = readStartupAtDeadline
        self.makeStageRoot = makeStageRoot ?? {
            Self.uniqueStageRoot(fileManager: fileManager)
        }
    }

    package func admit(
        verification trustedVerification:
            MojoRuntimeWorkerBundleVerification,
        inputResources: MojoRuntimeWorkerInputResources? = nil,
        startupDeadline: ContinuousClock.Instant,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration,
        lifetime: MojoRuntimeWorkerLifetime = MojoRuntimeWorkerLifetime()
    ) throws -> MojoRuntimeWorkerAdmittedProcess {
        try Self.requireAdmissionActive(until: startupDeadline)
        let stageRoot = makeStageRoot()
        var ownsStageRoot = false
        var stage: MojoRuntimeWorkerPrivateStage?
        var process: MojoPOSIXWorkerProcess?

        do {
            try Self.requireAdmissionActive(until: startupDeadline)
            do {
                try fileManager.createDirectory(
                    at: stageRoot,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                ownsStageRoot = true
            } catch {
                throw MojoRuntimeWorkerError.privateStageCreationFailed
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            try Self.verifyPrivatePermissions(
                at: stageRoot,
                fileManager: fileManager
            )
            try Self.requireAdmissionActive(until: startupDeadline)

            let bundleURL = stageRoot.appendingPathComponent(
                "bundle",
                isDirectory: true
            )
            stage = MojoRuntimeWorkerPrivateStage(
                rootURL: stageRoot,
                bundleURL: bundleURL
            )
            do {
                try copyItem(
                    trustedVerification.verifiedBundleURL,
                    bundleURL
                )
            } catch {
                throw MojoRuntimeWorkerError.privateStageCopyFailed
            }
            try Self.requireAdmissionActive(until: startupDeadline)

            let stagedVerification: MojoRuntimeWorkerBundleVerification
            do {
                stagedVerification = try verify(bundleURL)
            } catch {
                throw MojoRuntimeWorkerError.stagedVerificationFailed
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            guard trustedVerification.hasSameRuntimeSemantics(
                as: stagedVerification
            ) else {
                throw MojoRuntimeWorkerError.stagedProjectionMismatch
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            try Self.verifyPrivatePermissions(
                at: stageRoot,
                fileManager: fileManager
            )
            try Self.requireAdmissionActive(until: startupDeadline)
            let executableURL = try Self.verifiedExecutableURL(
                in: stagedVerification
            )
            try Self.requireAdmissionActive(until: startupDeadline)

            var environment: [String: String] = [:]
            if let inputResources {
                let resourceDirectory = try stageInputResources(
                    inputResources, in: stageRoot, deadline: startupDeadline
                )
                environment[
                    MojoRuntimeWorkerInputResources.directoryEnvironmentKey
                ] = resourceDirectory.path
                environment[
                    MojoRuntimeWorkerInputResources.countEnvironmentKey
                ] = String(inputResources.count)
                environment[
                    MojoRuntimeWorkerInputResources.bytesEnvironmentKey
                ] = String(inputResources.aggregateByteCount)
                environment[
                    MojoRuntimeWorkerInputResources.sha256EnvironmentKey
                ] = inputResources.aggregateSHA256
                environment[
                    MojoRuntimeWorkerInputResources
                        .runtimeLibraryDirectoryEnvironmentKey
                ] =
                    bundleURL.appendingPathComponent("lib", isDirectory: true).path
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            do {
                process = try spawn(executableURL.path, [], environment)
            } catch {
                throw MojoRuntimeWorkerError.workerSpawnFailed
            }
            guard let process else {
                throw MojoRuntimeWorkerError.workerSpawnFailed
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            let startup: MojoRuntimeWorkerStartupResult
            if let readStartupAtDeadline {
                startup = try readStartupAtDeadline(
                    process,
                    stagedVerification,
                    startupDeadline
                )
            } else {
                let clock = ContinuousClock()
                let remaining = clock.now.duration(to: startupDeadline)
                guard remaining > .zero else {
                    throw MojoRuntimeWorkerError.startupTimedOut
                }
                startup = try readStartup(
                    process,
                    stagedVerification,
                    remaining
                )
            }
            try Self.requireAdmissionActive(until: startupDeadline)
            let limits = try MojoRuntimeProtocolLimits(
                maximumFramePayloadBytes:
                    stagedVerification.maximumFramePayloadBytes
            )
            guard let stage else {
                throw MojoRuntimeWorkerError.privateStageCreationFailed
            }
            return MojoRuntimeWorkerAdmittedProcess(
                verification: stagedVerification,
                process: process,
                stage: stage,
                protocolLimits: limits,
                sequence: startup.sequence,
                startupDiagnostics: startup.diagnostics
            )
        } catch {
            let primary = Self.workerError(error)
            let ownedStageRoot: URL?
            if ownsStageRoot {
                ownedStageRoot = stage?.rootURL ?? stageRoot
            } else {
                ownedStageRoot = nil
            }
            let cleanupFailures = rollback(
                process: process,
                stageRoot: ownedStageRoot,
                lifetime: lifetime,
                terminationGracePeriod: terminationGracePeriod,
                forcedCleanup: forcedCleanup
            )
            guard cleanupFailures.isEmpty else {
                throw MojoRuntimeWorkerError.cleanupFailed(
                    primary: .worker(primary),
                    failures: cleanupFailures
                )
            }
            throw primary
        }
    }

    package static func verifyPrivatePermissions(
        at rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(
                atPath: rootURL.path
            )
        } catch {
            throw MojoRuntimeWorkerError.privateStageCreationFailed
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MojoRuntimeWorkerError.privateStageCreationFailed
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? -1
        let accessPermissions = permissions & 0o777
        guard accessPermissions == 0o700 else {
            throw MojoRuntimeWorkerError.privateStagePermissions(
                actual: accessPermissions
            )
        }
    }

    package static func verifiedExecutableURL(
        in verification: MojoRuntimeWorkerBundleVerification
    ) throws -> URL {
        let relativePath = verification.executable.relativePath
        let pathComponents = NSString(string: relativePath).pathComponents
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !pathComponents.contains("."),
              !pathComponents.contains("..") else {
            throw MojoRuntimeWorkerError.invalidExecutablePath
        }
        let rootURL = verification.verifiedBundleURL.standardizedFileURL
        let executableURL = rootURL.appendingPathComponent(relativePath)
            .standardizedFileURL
        let rootComponents = rootURL.pathComponents
        let executableComponents = executableURL.pathComponents
        guard executableComponents.count > rootComponents.count,
              executableComponents.starts(with: rootComponents) else {
            throw MojoRuntimeWorkerError.invalidExecutablePath
        }
        return executableURL
    }

    private static func uniqueStageRoot(
        fileManager: FileManager
    ) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-worker-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private static func requireNotCancelled() throws {
        let isCancelled = withUnsafeCurrentTask { task in
            task?.isCancelled ?? false
        }
        guard !isCancelled else {
            throw MojoRuntimeWorkerError.cancellationRequested
        }
    }

    private func stageInputResources(
        _ resources: MojoRuntimeWorkerInputResources,
        in rootURL: URL,
        deadline: ContinuousClock.Instant
    ) throws -> URL {
        try Self.requireAdmissionActive(until: deadline)
        let directory = rootURL.appendingPathComponent(
            MojoRuntimeWorkerInputResources.directoryName, isDirectory: true
        )
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw MojoRuntimeWorkerError.inputResourceDirectoryCreationFailed
        }
        do {
            try Self.verifyPrivatePermissions(
                at: directory, fileManager: fileManager
            )
        } catch {
            throw MojoRuntimeWorkerError.inputResourceDirectoryPermissionFailed
        }

        for resource in resources.values {
            try Self.requireAdmissionActive(until: deadline)
            let destination = directory.appendingPathComponent(
                resource.identifier.rawValue, isDirectory: false
            )
            _ = try stageInputResource(
                resource, destination: destination, deadline: deadline
            )
        }
        try Self.requireAdmissionActive(until: deadline)
        return directory
    }

    private func stageInputResource(
        _ resource: MojoRuntimeWorkerInputResource,
        destination: URL,
        deadline: ContinuousClock.Instant
    ) throws -> URL {
        try Self.requireAdmissionActive(until: deadline)
        let opened: (descriptor: Int32, byteCount: Int64)
        do {
            opened = try MojoPOSIXSupport.openRegularInputFile(path: resource.fileURL.path)
        } catch {
            throw MojoRuntimeWorkerError.inputResourceUnavailable
        }
        let input = FileHandle(fileDescriptor: opened.descriptor, closeOnDealloc: true)
        var output: FileHandle?
        var primary: MojoRuntimeWorkerError?
        do {
            guard opened.byteCount == resource.expectedByteCount else {
                throw MojoRuntimeWorkerError.inputResourceByteCountMismatch
            }
            guard fileManager.createFile(
                atPath: destination.path, contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw MojoRuntimeWorkerError.inputResourceCopyFailed
            }
            let target = try FileHandle(forUpdating: destination)
            output = target
            var remaining = resource.expectedByteCount
            while remaining > 0 {
                try Self.requireAdmissionActive(until: deadline)
                let chunk = try input.read(upToCount: Int(min(remaining, 1_048_576)))
                guard let chunk, !chunk.isEmpty else {
                    throw MojoRuntimeWorkerError.inputResourceByteCountMismatch
                }
                try target.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
            if let extra = try input.read(upToCount: 1), !extra.isEmpty {
                throw MojoRuntimeWorkerError.inputResourceByteCountMismatch
            }
            try target.seek(toOffset: 0)
            var digest = SHA256()
            remaining = resource.expectedByteCount
            while remaining > 0 {
                try Self.requireAdmissionActive(until: deadline)
                let chunk = try target.read(upToCount: Int(min(remaining, 1_048_576)))
                guard let chunk, !chunk.isEmpty else {
                    throw MojoRuntimeWorkerError.inputResourceByteCountMismatch
                }
                digest.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == resource.expectedSHA256 else {
                throw MojoRuntimeWorkerError.inputResourceDigestMismatch
            }
            try Self.requireAdmissionActive(until: deadline)
        } catch let error as MojoRuntimeWorkerError {
            primary = error
        } catch {
            primary = .inputResourceCopyFailed
        }
        var cleanupFailures: [MojoRuntimeWorkerCleanupFailure] = []
        if let output {
            do { try output.close() }
            catch { cleanupFailures.append(.inputResourceCloseFailed) }
        }
        do { try input.close() }
        catch { cleanupFailures.append(.inputResourceCloseFailed) }
        guard cleanupFailures.isEmpty else {
            throw MojoRuntimeWorkerError.cleanupFailed(
                primary: primary.map { .worker($0) }, failures: cleanupFailures
            )
        }
        if let primary { throw primary }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o400], ofItemAtPath: destination.path
            )
            let attributes = try fileManager.attributesOfItem(atPath: destination.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400 else {
                throw MojoRuntimeWorkerError.inputResourcePermissionFailed
            }
        } catch {
            throw MojoRuntimeWorkerError.inputResourcePermissionFailed
        }
        try Self.requireAdmissionActive(until: deadline)
        return destination
    }

    private static func requireAdmissionActive(
        until deadline: ContinuousClock.Instant
    ) throws {
        try requireNotCancelled()
        guard ContinuousClock().now < deadline else {
            throw MojoRuntimeWorkerError.startupTimedOut
        }
    }

    private func rollback(
        process: MojoPOSIXWorkerProcess?,
        stageRoot: URL?,
        lifetime: MojoRuntimeWorkerLifetime,
        terminationGracePeriod: Duration,
        forcedCleanup: Duration
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        if let process {
            return MojoRuntimeWorkerTerminalizer.cleanupAdmissionFailure(
                process: process,
                stageRoot: stageRoot,
                terminationGracePeriod: terminationGracePeriod,
                forcedCleanup: forcedCleanup,
                lifetime: lifetime
            ).failures
        }
        guard let stageRoot else {
            return []
        }
        return Self.finalizePrivateStage(
            at: stageRoot,
            processLifetimeEnded: true,
            fileManager: fileManager
        ).map { [$0] } ?? []
    }

    package static func finalizePrivateStage(
        at stageRoot: URL,
        processLifetimeEnded: Bool,
        fileManager: FileManager = .default,
        removeItem: RemoveItem? = nil
    ) -> MojoRuntimeWorkerCleanupFailure? {
        guard processLifetimeEnded else {
            return .privateStageRetained
        }
        do {
            if let removeItem {
                try removeItem(stageRoot)
            } else {
                try fileManager.removeItem(at: stageRoot)
            }
            return nil
        } catch {
            let cocoaError = error as NSError
            if cocoaError.domain == NSCocoaErrorDomain,
               cocoaError.code == NSFileNoSuchFileError {
                return nil
            }
            return .privateStageRemovalFailed
        }
    }

    private static func workerError(_ error: Error) -> MojoRuntimeWorkerError {
        if let error = error as? MojoRuntimeWorkerError { return error }
        return .startupProtocolFailed
    }
}
