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
    package typealias MakeStageRoot = () -> URL

    private static let reapTimeout = Duration.seconds(2)
    private static let reapPollInterval: TimeInterval = 0.005

    private let fileManager: FileManager
    private let verify: Verify
    private let spawn: Spawn
    private let readStartup: ReadStartup
    private let makeStageRoot: MakeStageRoot

    package init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
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
        makeStageRoot = {
            Self.uniqueStageRoot(fileManager: fileManager)
        }
    }

    package init(
        fileManager: FileManager,
        verify: @escaping Verify,
        spawn: @escaping Spawn,
        readStartup: @escaping ReadStartup,
        makeStageRoot: MakeStageRoot? = nil
    ) {
        self.fileManager = fileManager
        self.verify = verify
        self.spawn = spawn
        self.readStartup = readStartup
        self.makeStageRoot = makeStageRoot ?? {
            Self.uniqueStageRoot(fileManager: fileManager)
        }
    }

    package func admit(
        verification trustedVerification:
            MojoRuntimeWorkerBundleVerification,
        startupTimeout: Duration
    ) throws -> MojoRuntimeWorkerAdmittedProcess {
        let stageRoot = makeStageRoot()
        var ownsStageRoot = false
        var stage: MojoRuntimeWorkerPrivateStage?
        var process: MojoPOSIXWorkerProcess?

        do {
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
            try Self.verifyPrivatePermissions(
                at: stageRoot,
                fileManager: fileManager
            )

            let bundleURL = stageRoot.appendingPathComponent(
                "bundle",
                isDirectory: true
            )
            stage = MojoRuntimeWorkerPrivateStage(
                rootURL: stageRoot,
                bundleURL: bundleURL
            )
            do {
                try fileManager.copyItem(
                    at: trustedVerification.verifiedBundleURL,
                    to: bundleURL
                )
            } catch {
                throw MojoRuntimeWorkerError.privateStageCopyFailed
            }

            let stagedVerification: MojoRuntimeWorkerBundleVerification
            do {
                stagedVerification = try verify(bundleURL)
            } catch {
                throw MojoRuntimeWorkerError.stagedVerificationFailed
            }
            guard trustedVerification.hasSameRuntimeSemantics(
                as: stagedVerification
            ) else {
                throw MojoRuntimeWorkerError.stagedProjectionMismatch
            }
            try Self.verifyPrivatePermissions(
                at: stageRoot,
                fileManager: fileManager
            )
            let executableURL = try Self.verifiedExecutableURL(
                in: stagedVerification
            )

            do {
                process = try spawn(executableURL.path, [], [:])
            } catch {
                throw MojoRuntimeWorkerError.workerSpawnFailed
            }
            guard let process else {
                throw MojoRuntimeWorkerError.workerSpawnFailed
            }
            let startup = try readStartup(
                process,
                stagedVerification,
                startupTimeout
            )
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
                stageRoot: ownedStageRoot
            )
            guard cleanupFailures.isEmpty else {
                throw MojoRuntimeWorkerError.cleanupFailed(
                    primary: primary,
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

    private func rollback(
        process: MojoPOSIXWorkerProcess?,
        stageRoot: URL?
    ) -> [MojoRuntimeWorkerCleanupFailure] {
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        var mayRemoveStage = process == nil
        if let process {
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(
                    process.protocolDescriptor
                )
            } catch {
                failures.append(.transportCloseFailed)
            }
            let termination = Self.terminateAndReap(process)
            failures.append(contentsOf: termination.failures)
            mayRemoveStage = termination.mayRemoveStage
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(
                    process.diagnosticDescriptor
                )
            } catch {
                failures.append(.diagnosticsCloseFailed)
            }
        }
        if let stageRoot,
           fileManager.fileExists(atPath: stageRoot.path) {
            if let stageFailure = Self.finalizePrivateStage(
                at: stageRoot,
                processLifetimeEnded: mayRemoveStage,
                fileManager: fileManager
            ) {
                failures.append(stageFailure)
            }
        }
        return failures
    }

    package static func finalizePrivateStage(
        at stageRoot: URL,
        processLifetimeEnded: Bool,
        fileManager: FileManager = .default
    ) -> MojoRuntimeWorkerCleanupFailure? {
        guard fileManager.fileExists(atPath: stageRoot.path) else {
            return nil
        }
        guard processLifetimeEnded else {
            return .privateStageRetained
        }
        do {
            try fileManager.removeItem(at: stageRoot)
            return nil
        } catch {
            return .privateStageRemovalFailed
        }
    }

    private struct TerminationOutcome {
        let mayRemoveStage: Bool
        let failures: [MojoRuntimeWorkerCleanupFailure]
    }

    private struct ProcessGroupOutcome {
        let terminated: Bool
        let failures: [MojoRuntimeWorkerCleanupFailure]
    }

    private static func terminateAndReap(
        _ process: MojoPOSIXWorkerProcess
    ) -> TerminationOutcome {
        var failures: [MojoRuntimeWorkerCleanupFailure] = []
        let processID = process.processID
        guard processID > 0 else {
            return TerminationOutcome(
                mayRemoveStage: false,
                failures: [.processInspectionFailed]
            )
        }

        var reaped = false
        do {
            if try MojoPOSIXSupport.waitNoHang(processID: processID) != nil {
                reaped = true
            }
        } catch let error as MojoPOSIXSupportError
            where error == .childAlreadyReaped {
            failures.append(.processInspectionFailed)
            reaped = true
        } catch {
            failures.append(.processInspectionFailed)
        }

        var signalFailed = false
        if !reaped, MojoPOSIXSupport.processGroupIsAlive(processID) {
            do {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: processID,
                    signal: MojoPOSIXSupport.killSignal
                )
            } catch {
                signalFailed = true
            }
        }

        if !reaped {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: reapTimeout)
            while clock.now < deadline {
                do {
                    if try MojoPOSIXSupport.waitNoHang(
                        processID: processID
                    ) != nil {
                        reaped = true
                        break
                    }
                } catch let error as MojoPOSIXSupportError
                    where error == .childAlreadyReaped {
                    failures.append(.processReapFailed)
                    reaped = true
                    break
                } catch {
                    failures.append(.processReapFailed)
                    break
                }
                Thread.sleep(forTimeInterval: reapPollInterval)
            }
        }
        if !reaped {
            do {
                reaped = try MojoPOSIXSupport.waitNoHang(
                    processID: processID
                ) != nil
            } catch let error as MojoPOSIXSupportError
                where error == .childAlreadyReaped {
                failures.append(.processReapFailed)
                reaped = true
            } catch {
                failures.append(.processReapFailed)
            }
        }
        if !reaped {
            failures.append(.processReapFailed)
        }
        if signalFailed, !reaped {
            failures.append(.processTerminationFailed)
        }
        let group = terminateRemainingProcessGroup(processID)
        failures.append(contentsOf: group.failures)
        return TerminationOutcome(
            mayRemoveStage: reaped && group.terminated,
            failures: failures
        )
    }

    private static func terminateRemainingProcessGroup(
        _ processID: MojoPOSIXSupport.ProcessID
    ) -> ProcessGroupOutcome {
        guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
            return ProcessGroupOutcome(terminated: true, failures: [])
        }
        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: MojoPOSIXSupport.killSignal
            )
        } catch {
            guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
                return ProcessGroupOutcome(terminated: true, failures: [])
            }
            return ProcessGroupOutcome(
                terminated: false,
                failures: [.processGroupTerminationFailed]
            )
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: reapTimeout)
        while clock.now < deadline {
            guard MojoPOSIXSupport.processGroupIsAlive(processID) else {
                return ProcessGroupOutcome(terminated: true, failures: [])
            }
            Thread.sleep(forTimeInterval: reapPollInterval)
        }
        guard !MojoPOSIXSupport.processGroupIsAlive(processID) else {
            return ProcessGroupOutcome(
                terminated: false,
                failures: [.processGroupTerminationFailed]
            )
        }
        return ProcessGroupOutcome(terminated: true, failures: [])
    }

    private static func workerError(_ error: Error) -> MojoRuntimeWorkerError {
        if let error = error as? MojoRuntimeWorkerError { return error }
        return .startupProtocolFailed
    }
}
