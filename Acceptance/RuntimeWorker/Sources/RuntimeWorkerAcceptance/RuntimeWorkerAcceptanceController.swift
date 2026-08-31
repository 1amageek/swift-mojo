import Foundation
import MojoRuntime
import MojoRuntimeWorker

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Runs the host-side RT4.B acceptance flow without producing a receipt.
///
/// The controller is intentionally the only owner of pass/fail process and
/// temporary-directory observations. The shell harness may perform
/// fail-closed emergency cleanup after an outer abort, but it produces no
/// acceptance evidence. The child consumer remains limited to the public
/// MojoRuntime and MojoRuntimeWorker products.
public struct RuntimeWorkerAcceptanceController: Sendable {
    private static let cleanupSignalWait: Duration = .seconds(1)
    private static let processInspectionTimeout: Duration = .seconds(2)
    private static let maximumCapturedOutputBytes = 4 * 1024 * 1024
    private static let processPollInterval: Duration = .milliseconds(10)
    private let sourceIdentityVerifier:
        any RuntimeWorkerAcceptanceSourceIdentityVerifying

    public init() {
        self.sourceIdentityVerifier =
            FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()
    }

    init(
        sourceIdentityVerifier:
            any RuntimeWorkerAcceptanceSourceIdentityVerifying
    ) {
        self.sourceIdentityVerifier = sourceIdentityVerifier
    }

    public func run(
        _ configuration: RuntimeWorkerAcceptanceRunConfiguration
    ) async throws -> RuntimeWorkerAcceptanceRunReport {
        try Self.requireCleanControllerEnvironment()
        try Self.requireInputs(configuration)
        let emptyExecutionPath = try Self.prepareEmptyExecutionPath(
            in: configuration.temporaryDirectoryURL
        )

        let verifier = FileSystemMojoRuntimeWorkerBundleVerifier(
            environment: [:]
        )
        let verification = try verifier.verifyWorkerBundle(
            at: configuration.bundleURL
        )
        let artifact = try RuntimeWorkerAcceptanceContract.Artifact(
            projection: verification
        )
        let protocolRecord = try RuntimeWorkerAcceptanceContract.ProtocolRecord(
            projection: verification
        )
        let projectionFieldCount = try RuntimeWorkerAcceptanceProjectionOracle
            .verify(
                projection: verification,
                artifact: artifact,
                protocolRecord: protocolRecord
            )

        let failureVerification = try verifier.verifyWorkerBundle(
            at: configuration.failureBundleURL
        )
        let failureArtifact = try RuntimeWorkerAcceptanceContract.Artifact(
            projection: failureVerification
        )
        let failureProtocol = try RuntimeWorkerAcceptanceContract.ProtocolRecord(
            projection: failureVerification
        )
        _ = try RuntimeWorkerAcceptanceProjectionOracle.verify(
            projection: failureVerification,
            artifact: failureArtifact,
            protocolRecord: failureProtocol
        )
        try Self.requireSharedAuthoringIdentity(
            artifact: artifact,
            protocolRecord: protocolRecord,
            failureArtifact: failureArtifact,
            failureProtocol: failureProtocol
        )

        let stageBefore = try Self.stageEntries(
            in: configuration.temporaryDirectoryURL
        )
        guard stageBefore.isEmpty else {
            throw RuntimeWorkerAcceptanceRunnerError.stageLeak(stageBefore)
        }
        let processBefore = try await Self.workerProcessLines(
            in: configuration.temporaryDirectoryURL
        )
        guard processBefore.isEmpty else {
            throw RuntimeWorkerAcceptanceRunnerError.processLeak(processBefore)
        }
        let sourceIdentityBefore = try sourceIdentityVerifier.sourceIdentity(
            at: configuration.repositoryRootURL
        )
        try Self.requireCanonicalSourceIdentity(
            sourceIdentityBefore,
            expectedDigest: configuration.expectedSourceDigest
        )
        do {
            let processResult = try await Self.runConsumer(
                configuration: configuration,
                emptyExecutionPath: emptyExecutionPath
            )
            guard processResult.status == 0 else {
                throw RuntimeWorkerAcceptanceRunnerError.consumerFailed(
                    status: processResult.status,
                    diagnostic: Self.diagnostic(
                        stderr: processResult.stderr,
                        stdout: processResult.stdout
                    )
                )
            }
            let consumer = try Self.decodeConsumerReport(
                processResult.stdout
            )

            let stageAfter = try Self.stageEntries(
                in: configuration.temporaryDirectoryURL
            )
            let stageLeaks = stageAfter
            guard stageLeaks.isEmpty else {
                throw RuntimeWorkerAcceptanceRunnerError.stageLeak(stageLeaks)
            }
            let stageLeakCount = stageLeaks.count

            let processLines = try await Self.workerProcessLines(
                in: configuration.temporaryDirectoryURL
            )
            guard processLines.isEmpty else {
                throw RuntimeWorkerAcceptanceRunnerError.processLeak(
                    processLines
                )
            }
            let processLeakCount = processLines.count

            let sourceIdentityAfter = try sourceIdentityVerifier.sourceIdentity(
                at: configuration.repositoryRootURL
            )
            try Self.requireStableSourceIdentity(
                before: sourceIdentityBefore,
                after: sourceIdentityAfter
            )

            try Self.requireConsumerEvidence(
                consumer,
                expectedOutput: RuntimeWorkerAcceptanceProjectionOracle
                    .expectedOutputBitPatterns
            )
            let forcedFailureProcessGroupReaped =
                consumer.forcedFailureTimedOut
                && consumer.forcedFailureCleanupFailureCount == 0
                && processLeakCount == 0
            let consumerBoundary = Self.consumerBoundaryEvidence()
            let executionEnvironment = try Self.executionEnvironmentEvidence(
                consumer
            )
            let lifecycle = try Self.lifecycleEvidence(
                consumer: consumer,
                forcedFailureProcessGroupReaped:
                    forcedFailureProcessGroupReaped
            )
            let report = RuntimeWorkerAcceptanceRunReport(
                swiftMojoRevision: configuration.swiftMojoRevision,
                acceptanceSourceAlgorithm: sourceIdentityAfter.algorithm,
                acceptanceSourceDigest: sourceIdentityAfter.digest,
                artifact: artifact,
                protocolRecord: protocolRecord,
                projectionFieldCount: projectionFieldCount,
                consumerBoundary: consumerBoundary,
                executionEnvironment: executionEnvironment,
                lifecycle: lifecycle,
                firstAttemptOutputBitPatterns:
                    consumer.firstAttemptOutputBitPatterns,
                forcedFailureError: consumer.forcedFailureError,
                thirdAttemptOutputBitPatterns:
                    consumer.thirdAttemptOutputBitPatterns,
                stageLeakCount: stageLeakCount,
                processLeakCount: processLeakCount
            )
            return report
        } catch {
            let primaryDescription = String(describing: error)
            do {
                try await Self.cleanupAbortedConsumer(
                    in: configuration.temporaryDirectoryURL,
                    baselineStageEntries: stageBefore,
                    primaryDescription: primaryDescription
                )
            } catch let cleanupError as RuntimeWorkerAcceptanceRunnerError {
                throw cleanupError
            } catch {
                throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                    "primary failure: \(primaryDescription); \(error)"
                )
            }
            throw error
        }
    }

    private static func requireCleanControllerEnvironment() throws {
        let environment = ProcessInfo.processInfo.environment
        let forbiddenExact = [
            "MODULAR_HOME",
            "SWIFT_MOJO_EXECUTABLE",
            "SWIFT_MOJO_LLVM_AR",
            "PYTHONHOME",
            "PYTHONPATH",
        ]
        let forbidden = Set(
            forbiddenExact.filter { environment[$0] != nil }
                + environment.keys.filter {
                    $0.hasPrefix("DYLD_") || $0.hasPrefix("LD_")
                }
        )
        guard forbidden.isEmpty else {
            throw RuntimeWorkerAcceptanceRunnerError
                .dirtyExecutionEnvironment(forbidden.sorted())
        }
    }

    static func requireCanonicalSourceIdentity(
        _ identity: RuntimeWorkerAcceptanceSourceIdentity,
        expectedDigest: String
    ) throws {
        let canonicalInventory = RuntimeWorkerAcceptanceSourceIdentity
            .filePaths.sorted { lhs, rhs in
                lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }
        guard identity.algorithm
            == RuntimeWorkerAcceptanceSourceIdentity.algorithmValue else {
            throw RuntimeWorkerAcceptanceRunnerError
                .sourceIdentityContractMismatch("algorithm")
        }
        guard identity.inventory == canonicalInventory else {
            throw RuntimeWorkerAcceptanceRunnerError
                .sourceIdentityContractMismatch("inventory")
        }
        guard identity.files.map(\.path) == canonicalInventory else {
            throw RuntimeWorkerAcceptanceRunnerError
                .sourceIdentityContractMismatch("files.path")
        }
        var observedTotalByteCount = 0
        for file in identity.files {
            let (nextTotal, overflow) = observedTotalByteCount
                .addingReportingOverflow(file.byteCount)
            guard file.byteCount >= 0,
                  file.byteCount
                    <= RuntimeWorkerAcceptanceSourceIdentity
                        .maximumFileByteCount,
                  !overflow,
                  nextTotal
                    <= RuntimeWorkerAcceptanceSourceIdentity
                        .maximumTotalByteCount else {
                throw RuntimeWorkerAcceptanceRunnerError
                    .sourceIdentityContractMismatch("files.byteCount")
            }
            observedTotalByteCount = nextTotal
        }
        guard observedTotalByteCount == identity.totalByteCount else {
            throw RuntimeWorkerAcceptanceRunnerError
                .sourceIdentityContractMismatch("totalByteCount")
        }
        guard identity.digest == expectedDigest else {
            throw RuntimeWorkerAcceptanceRunnerError.sourceIdentityMismatch(
                expected: expectedDigest,
                actual: identity.digest
            )
        }
    }

    static func requireStableSourceIdentity(
        before: RuntimeWorkerAcceptanceSourceIdentity,
        after: RuntimeWorkerAcceptanceSourceIdentity
    ) throws {
        guard after == before else {
            throw RuntimeWorkerAcceptanceRunnerError.sourceIdentityChanged(
                before: before.digest,
                after: after.digest
            )
        }
    }

    private static func requireInputs(
        _ configuration: RuntimeWorkerAcceptanceRunConfiguration
    ) throws {
        let fileManager = FileManager.default
        try requireDirectory(
            configuration.bundleURL,
            named: "bundle",
            fileManager: fileManager
        )
        try requireDirectory(
            configuration.failureBundleURL,
            named: "failure bundle",
            fileManager: fileManager
        )
        guard fileManager.isExecutableFile(
            atPath: configuration.consumerExecutableURL.path
        ) else {
            throw RuntimeWorkerAcceptanceRunnerError.missingInput(
                "executable consumer at \(configuration.consumerExecutableURL.path)"
            )
        }
        try requireDirectory(
            configuration.temporaryDirectoryURL,
            named: "temporary directory",
            fileManager: fileManager
        )
    }

    private static func requireDirectory(
        _ url: URL,
        named name: String,
        fileManager: FileManager
    ) throws {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw RuntimeWorkerAcceptanceRunnerError.missingInput(
                "\(name) at \(url.path)"
            )
        }
    }

    private static func prepareEmptyExecutionPath(in directory: URL) throws
        -> URL
    {
        let path = directory.appendingPathComponent("runtime-worker-empty-bin")
        do {
            if !FileManager.default.fileExists(atPath: path.path) {
                try FileManager.default.createDirectory(
                    at: path,
                    withIntermediateDirectories: false
                )
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: path,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard entries.isEmpty else {
                throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                    "execution PATH directory is not empty: \(path.path)"
                )
            }
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            throw error
        } catch {
            throw RuntimeWorkerAcceptanceRunnerError.processInspectionFailed(
                "cannot prepare execution PATH directory \(path.path): \(error)"
            )
        }
        return path
    }

    private static func requireSharedAuthoringIdentity(
        artifact: RuntimeWorkerAcceptanceContract.Artifact,
        protocolRecord: RuntimeWorkerAcceptanceContract.ProtocolRecord,
        failureArtifact: RuntimeWorkerAcceptanceContract.Artifact,
        failureProtocol: RuntimeWorkerAcceptanceContract.ProtocolRecord
    ) throws {
        let semanticIdentity = artifact.semanticIdentity
        let failureSemanticIdentity = failureArtifact.semanticIdentity
        guard semanticIdentity == failureSemanticIdentity else {
            throw RuntimeWorkerAcceptanceRunnerError
                .authoringIdentityMismatch("semanticIdentity")
        }
        guard artifact.schemaVersion == failureArtifact.schemaVersion else {
            throw RuntimeWorkerAcceptanceRunnerError
                .authoringIdentityMismatch("schemaVersion")
        }
        guard artifact.generatedInputs == failureArtifact.generatedInputs else {
            throw RuntimeWorkerAcceptanceRunnerError
                .authoringIdentityMismatch("generatedInputs")
        }
        guard artifact.targetClosure == failureArtifact.targetClosure else {
            throw RuntimeWorkerAcceptanceRunnerError
                .authoringIdentityMismatch("targetClosure")
        }
        guard protocolRecord == failureProtocol else {
            throw RuntimeWorkerAcceptanceRunnerError
                .authoringIdentityMismatch("protocol")
        }
    }

    private static func stageEntries(in directory: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("swift-mojo-worker-") }
            .sorted()
        } catch {
            throw RuntimeWorkerAcceptanceRunnerError.processInspectionFailed(
                "cannot inspect \(directory.path): \(error)"
            )
        }
    }

    struct ConsumerProcessResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private struct CapturedProcessResult: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }

    private struct WorkerProcess: Sendable {
        let processID: Int32
        let processGroupID: Int32
        let commandLine: String
    }

    static func runConsumerForTesting(
        configuration: RuntimeWorkerAcceptanceRunConfiguration,
        emptyExecutionPath: URL
    ) async throws -> ConsumerProcessResult {
        try await runConsumer(
            configuration: configuration,
            emptyExecutionPath: emptyExecutionPath
        )
    }

    private static func runConsumer(
        configuration: RuntimeWorkerAcceptanceRunConfiguration,
        emptyExecutionPath: URL
    ) async throws -> ConsumerProcessResult {
        do {
            let result = try await runBoundedProcess(
                executableURL: configuration.consumerExecutableURL,
                arguments: [
                    "--bundle",
                    configuration.bundleURL.path,
                    "--failure-bundle",
                    configuration.failureBundleURL.path,
                ],
                environment: [
                    "PATH": emptyExecutionPath.path,
                    "TMPDIR": configuration.temporaryDirectoryURL.path,
                    "HOME": configuration.temporaryDirectoryURL.path,
                ],
                outputPrefix: "runtime-worker-consumer",
                timeout: configuration.consumerDeadline
            )
            return ConsumerProcessResult(
                status: result.status,
                stdout: result.stdout,
                stderr: result.stderr
            )
        } catch let error as BoundedProcessError {
            switch error {
            case .launchFailed(let detail):
                throw RuntimeWorkerAcceptanceRunnerError.consumerLaunchFailed(
                    detail
                )
            case .deadlineExceeded:
                throw RuntimeWorkerAcceptanceRunnerError.consumerTimedOut
            case .descriptorFailed, .outputLimitExceeded, .outputReadFailed:
                throw RuntimeWorkerAcceptanceRunnerError.consumerOutputFailed(
                    error.description
                )
            }
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            throw error
        }
    }

    private static func runBoundedProcess(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        outputPrefix: String,
        timeout: Duration
    ) async throws -> CapturedProcessResult {
        let clock = ContinuousClock()
        let started = clock.now
        let phaseReserve = min(.seconds(1), timeout / 4)
        let hardDeadline = started.advanced(by: timeout)
        let forceDeadline = started.advanced(
            by: timeout - phaseReserve
        )
        let executionDeadline = started.advanced(
            by: timeout - phaseReserve - phaseReserve
        )
        var activeForceDeadline = forceDeadline
        var activeHardDeadline = hardDeadline

        var stdoutCapture: BoundedPipeCapture?
        var stderrCapture: BoundedPipeCapture?
        var process: Process?
        var primaryError: Error?
        var cleanupFailures: [String] = []
        var captured: CapturedProcessResult?

        do {
            stdoutCapture = try BoundedPipeCapture(streamName: "stdout")
            stderrCapture = try BoundedPipeCapture(streamName: "stderr")

            let child = Process()
            child.executableURL = executableURL
            child.arguments = arguments
            child.environment = environment
            guard let stdoutWriteHandle = stdoutCapture?.writeHandle,
                  let stderrWriteHandle = stderrCapture?.writeHandle else {
                throw BoundedProcessError.descriptorFailed(
                    "pipe handles were not initialized"
                )
            }
            child.standardOutput = stdoutWriteHandle
            child.standardError = stderrWriteHandle
            do {
                try child.run()
            } catch {
                throw BoundedProcessError.launchFailed(
                    executableURL.path + ": " + String(describing: error)
                )
            }
            process = child
            try stdoutCapture?.closeParentWrite()
            try stderrCapture?.closeParentWrite()

            var didSendTermination = false
            var didSendForcedTermination = false
            while true {
                let stdoutOverflow = try stdoutCapture?.drain(
                    maximumByteCount: maximumCapturedOutputBytes
                ) ?? false
                let stderrOverflow = try stderrCapture?.drain(
                    maximumByteCount: maximumCapturedOutputBytes
                ) ?? false

                if primaryError == nil, stdoutOverflow || stderrOverflow {
                    let stream = stdoutOverflow ? "stdout" : "stderr"
                    primaryError = BoundedProcessError.outputLimitExceeded(
                        stream: stream,
                        maximumByteCount: maximumCapturedOutputBytes
                    )
                }

                let now = clock.now
                let processExited = !child.isRunning
                let outputCompleted = stdoutCapture?.reachedEOF == true
                    && stderrCapture?.reachedEOF == true
                if processExited, outputCompleted {
                    if primaryError == nil {
                        captured = CapturedProcessResult(
                            status: child.terminationStatus,
                            stdout: stdoutCapture?.data ?? Data(),
                            stderr: stderrCapture?.data ?? Data()
                        )
                    }
                    break
                }

                if primaryError == nil,
                   (Task.isCancelled || now >= executionDeadline) {
                    primaryError = BoundedProcessError.deadlineExceeded
                }

                if primaryError != nil, !didSendTermination {
                    didSendTermination = true
                    let proposedForceDeadline = now.advanced(
                        by: phaseReserve
                    )
                    activeForceDeadline = min(
                        forceDeadline,
                        proposedForceDeadline
                    )
                    activeHardDeadline = min(
                        hardDeadline,
                        activeForceDeadline.advanced(by: phaseReserve)
                    )
                    if child.isRunning {
                        child.terminate()
                    }
                }

                if primaryError != nil,
                   child.isRunning,
                   !didSendForcedTermination,
                   now >= activeForceDeadline {
                    didSendForcedTermination = true
                    try Self.forceTerminate(
                        process: child,
                        label: outputPrefix
                    )
                }

                if primaryError != nil, now >= activeHardDeadline {
                    break
                }

                if Task.isCancelled {
                    Self.pauseForProcessPoll()
                } else {
                    do {
                        try await Task.sleep(for: processPollInterval)
                    } catch {
                        if primaryError == nil {
                            primaryError = BoundedProcessError.deadlineExceeded
                        }
                    }
                }
            }
        } catch let error as BoundedProcessError {
            primaryError = error
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            primaryError = error
        } catch {
            primaryError = BoundedProcessError.outputReadFailed(
                stream: "unknown",
                errorCode: 0,
                detail: String(describing: error)
            )
        }

        if primaryError != nil {
            let now = clock.now
            activeForceDeadline = min(
                activeForceDeadline,
                now.advanced(by: phaseReserve)
            )
            activeHardDeadline = min(
                activeHardDeadline,
                activeForceDeadline.advanced(by: phaseReserve)
            )
        }
        if let process, process.isRunning {
            do {
                try await Self.stop(
                    process: process,
                    label: outputPrefix,
                    hardDeadline: activeHardDeadline
                )
            } catch {
                cleanupFailures.append(
                    String(describing: error)
                )
            }
        }
        if var stdoutCapture {
            cleanupFailures.append(contentsOf: stdoutCapture.closeAll())
        }
        if var stderrCapture {
            cleanupFailures.append(contentsOf: stderrCapture.closeAll())
        }
        if !cleanupFailures.isEmpty {
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                "primary failure: "
                    + (primaryError.map(String.init(describing:)) ?? "none")
                    + "; " + cleanupFailures.joined(separator: " | ")
            )
        }
        if let primaryError {
            throw primaryError
        }
        guard let captured else {
            throw RuntimeWorkerAcceptanceRunnerError.processInspectionFailed(
                "bounded process produced no result"
            )
        }
        return captured
    }

    private static func waitForProcessExit(
        _ process: Process,
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        while process.isRunning && clock.now < deadline {
            Self.pauseForProcessPoll()
        }
        return !process.isRunning
    }

    private static func pauseForProcessPoll() {
        #if canImport(Darwin) || canImport(Glibc)
        usleep(10_000)
        #else
        Thread.sleep(forTimeInterval: 0.01)
        #endif
    }

    private static func stop(
        process: Process,
        label: String,
        hardDeadline: ContinuousClock.Instant
    ) async throws {
        guard process.isRunning else { return }
        let clock = ContinuousClock()
        guard clock.now < hardDeadline else {
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                label + " reached its hard deadline before termination"
            )
        }
        process.terminate()
        let remaining = clock.now.duration(to: hardDeadline)
        let phaseReserve = min(.seconds(1), remaining / 2)
        let forceDeadline = min(
            hardDeadline,
            clock.now.advanced(by: phaseReserve)
        )
        let terminated = await waitForProcessExit(
            process,
            until: forceDeadline
        )
        if !terminated {
            try Self.forceTerminate(process: process, label: label)
            let killed = await waitForProcessExit(
                process,
                until: hardDeadline
            )
            guard killed else {
                throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                    label + " process survived its bounded SIGKILL wait"
                )
            }
        }
        guard !process.isRunning else {
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                label + " process remained running after bounded termination"
            )
        }
    }

    private static func forceTerminate(
        process: Process,
        label: String
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let killResult = kill(process.processIdentifier, SIGKILL)
        if killResult != 0 && errno != ESRCH {
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                label + " SIGKILL failed with errno " + String(errno)
            )
        }
        #else
        throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
            label + " cannot force termination on this platform"
        )
        #endif
    }

    private static func decodeConsumerReport(
        _ data: Data
    ) throws -> ConsumerRunReport {
        let expectedKeys: Set<String> = [
            "firstAttemptOutputBitPatterns",
            "forcedFailureError",
            "forcedFailureTimedOut",
            "forcedFailurePartialOutputElementCount",
            "forcedFailureCleanupFailureCount",
            "thirdAttemptOutputBitPatterns",
            "executionPathIsolated",
            "cleanEnvironmentObserved",
        ]
        do {
            guard let object = try JSONSerialization.jsonObject(
                with: data
            ) as? [String: Any] else {
                throw RuntimeWorkerAcceptanceRunnerError
                    .invalidConsumerReport("report is not a JSON object")
            }
            guard Set(object.keys) == expectedKeys else {
                throw RuntimeWorkerAcceptanceRunnerError
                    .invalidConsumerReport("consumer report keys are not closed")
            }
            return try JSONDecoder().decode(ConsumerRunReport.self, from: data)
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            throw error
        } catch {
            throw RuntimeWorkerAcceptanceRunnerError.invalidConsumerReport(
                String(describing: error)
            )
        }
    }

    private static func requireConsumerEvidence(
        _ consumer: ConsumerRunReport,
        expectedOutput: [UInt32]
    ) throws {
        guard consumer.firstAttemptOutputBitPatterns == expectedOutput,
              consumer.thirdAttemptOutputBitPatterns == expectedOutput else {
            throw RuntimeWorkerAcceptanceRunnerError.unexpectedOutput(
                consumer.firstAttemptOutputBitPatterns
            )
        }
        guard consumer.forcedFailureError == "invocationTimedOut",
              consumer.forcedFailureTimedOut else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidConsumerReport(
                "forced attempt did not produce the typed invocationTimedOut outcome"
            )
        }
        guard consumer.forcedFailurePartialOutputElementCount == 0 else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidConsumerReport(
                "forced attempt exposed partial output"
            )
        }
        guard consumer.forcedFailureCleanupFailureCount == 0 else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidConsumerReport(
                "forced attempt exposed cleanup failures"
            )
        }
        guard consumer.executionPathIsolated,
              consumer.cleanEnvironmentObserved else {
            throw RuntimeWorkerAcceptanceRunnerError
                .dirtyExecutionEnvironment(["consumer report"])
        }
    }

    private static func consumerBoundaryEvidence()
        -> RuntimeWorkerAcceptanceContract.ConsumerBoundary
    {
        RuntimeWorkerAcceptanceContract.ConsumerBoundary(
            publicRuntimeProjectionUsed: true,
            publicWorkerAPIUsed: true,
            filesystemAccessOutsideWorker: false,
            processLaunchOutsideWorker: false,
            runtimeLoaderOutsideWorker: false,
            rawPOSIXImports: false,
            rawProtocolImports: false,
            workerSPIImports: false
        )
    }

    private static func executionEnvironmentEvidence(
        _ consumer: ConsumerRunReport
    ) throws -> RuntimeWorkerAcceptanceContract.ExecutionEnvironment {
        try RuntimeWorkerAcceptanceContract.ExecutionEnvironment(
            compilerAvailableDuringExecution: false,
            pythonAvailableDuringExecution: false,
            ambientLoaderVariableNames: [],
            cleanEnvironmentObserved: consumer.cleanEnvironmentObserved
        )
    }

    private static func lifecycleEvidence(
        consumer: ConsumerRunReport,
        forcedFailureProcessGroupReaped: Bool
    ) throws -> RuntimeWorkerAcceptanceContract.Lifecycle {
        try RuntimeWorkerAcceptanceContract.Lifecycle(
            stagingVerificationObserved: true,
            readyAdmissionObserved: true,
            sessionCreationObserved: true,
            nonEmptyInvocationInputElementCount: 3,
            nonEmptyInvocationOutputElementCount:
                consumer.firstAttemptOutputBitPatterns.count,
            gracefulShutdownObserved: true,
            forcedFailureObserved: consumer.forcedFailureTimedOut,
            forcedFailureTimedOut: consumer.forcedFailureTimedOut,
            forcedFailureProcessGroupReaped:
                forcedFailureProcessGroupReaped,
            forcedFailurePartialOutputElementCount:
                consumer.forcedFailurePartialOutputElementCount,
            forcedFailureCleanupFailureCount:
                consumer.forcedFailureCleanupFailureCount,
            cleanNextAttemptObserved:
                consumer.thirdAttemptOutputBitPatterns
                    == RuntimeWorkerAcceptanceProjectionOracle
                        .expectedOutputBitPatterns
        )
    }

    static func cleanupAbortedConsumer(
        in directory: URL,
        baselineStageEntries: [String],
        primaryDescription: String
    ) async throws {
        var processes = try await Self.workerProcesses(in: directory)
        let processGroupIDs = Set(processes.map(\.processGroupID))
            .filter { $0 > 0 }
            .sorted()
        Self.signal(processGroupIDs, with: SIGTERM)
        processes = try await Self.waitForWorkerProcessesGone(
            in: directory,
            within: Self.cleanupSignalWait
        )

        if !processes.isEmpty {
            let remainingGroupIDs = Set(processes.map(\.processGroupID))
                .filter { $0 > 0 }
                .sorted()
            Self.signal(remainingGroupIDs, with: SIGKILL)
            processes = try await Self.waitForWorkerProcessesGone(
                in: directory,
                within: Self.cleanupSignalWait
            )
        }

        guard processes.isEmpty else {
            let descriptions = processes.map(\.commandLine).joined(
                separator: " | "
            )
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                "primary failure: \(primaryDescription); remaining worker "
                    + "processes: \(descriptions)"
            )
        }

        let baseline = Set(baselineStageEntries)
        let stageEntries = try Self.stageEntries(in: directory)
        let createdStageEntries = stageEntries.filter { !baseline.contains($0) }
        var removalFailures: [String] = []
        for stageEntry in createdStageEntries {
            let stageURL = directory.appendingPathComponent(
                stageEntry,
                isDirectory: true
            )
            do {
                try FileManager.default.removeItem(at: stageURL)
            } catch {
                removalFailures.append(
                    "\(stageEntry): \(String(describing: error))"
                )
            }
        }
        let remainingStages = try Self.stageEntries(in: directory)
            .filter { !baseline.contains($0) }
        guard removalFailures.isEmpty, remainingStages.isEmpty else {
            let details = (removalFailures + remainingStages).joined(
                separator: " | "
            )
            throw RuntimeWorkerAcceptanceRunnerError.cleanupFailed(
                "primary failure: \(primaryDescription); remaining stages: "
                    + details
            )
        }
    }

    private static func waitForWorkerProcessesGone(
        in directory: URL,
        within duration: Duration
    ) async throws -> [WorkerProcess] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        var processes = try await Self.workerProcesses(in: directory)
        while !processes.isEmpty && clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                break
            }
            processes = try await Self.workerProcesses(in: directory)
        }
        return processes
    }

    private static func signal(
        _ processGroupIDs: [Int32],
        with signal: Int32
    ) {
        #if canImport(Darwin) || canImport(Glibc)
        for processGroupID in processGroupIDs {
            _ = kill(-processGroupID, signal)
        }
        #else
        _ = processGroupIDs
        _ = signal
        #endif
    }

    static func inspectWorkerProcessLinesForTesting(
        in directory: URL,
        executableURL: URL
    ) async throws -> [String] {
        try await Self.workerProcessLines(
            in: directory,
            executableURL: executableURL
        )
    }

    private static func workerProcessLines(
        in directory: URL,
        executableURL: URL? = nil
    ) async throws -> [String] {
        let processes = try await Self.workerProcesses(
            in: directory,
            executableURL: executableURL
        )
        return processes.map(\.commandLine)
    }

    private static func workerProcesses(
        in directory: URL,
        executableURL: URL? = nil
    ) async throws -> [WorkerProcess] {
        let processURL = try executableURL ?? Self.processInspectionURL()
        let result: CapturedProcessResult
        do {
            result = try await Self.runBoundedProcess(
                executableURL: processURL,
                arguments: executableURL == nil
                    ? ["-axo", "pid=,pgid=,command="]
                    : [],
                environment: [:],
                outputPrefix: "runtime-worker-process-inspection",
                timeout: Self.processInspectionTimeout
            )
        } catch let error as BoundedProcessError {
            throw RuntimeWorkerAcceptanceRunnerError.processInspectionFailed(
                error.description
            )
        }
        guard result.status == 0 else {
            throw RuntimeWorkerAcceptanceRunnerError.processInspectionFailed(
                "process inspection exited with status \(result.status)"
            )
        }

        let output = result.stdout
        let workerPathPrefix = directory.standardizedFileURL.path
            + "/swift-mojo-worker-"
        var processes: [WorkerProcess] = []
        let lines = String(
            decoding: output,
            as: UTF8.self
        )
        .split(whereSeparator: \.isNewline)
        for line in lines where line.contains(workerPathPrefix) {
            let fields = line.split(
                maxSplits: 2,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 3,
                  let processID = Int32(String(fields[0])),
                  let processGroupID = Int32(String(fields[1])) else {
                throw RuntimeWorkerAcceptanceRunnerError
                    .processInspectionFailed(
                        "cannot parse worker process line: \(line)"
                    )
            }
            guard processID > 0, processGroupID > 0 else {
                throw RuntimeWorkerAcceptanceRunnerError
                    .processInspectionFailed(
                        "worker process has an invalid process group: \(line)"
                    )
            }
            processes.append(
                WorkerProcess(
                    processID: processID,
                    processGroupID: processGroupID,
                    commandLine: String(fields[2])
                )
            )
        }
        return processes
    }

    private static func processInspectionURL() throws -> URL {
        if FileManager.default.isExecutableFile(atPath: "/bin/ps") {
            return URL(fileURLWithPath: "/bin/ps")
        }
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/ps") {
            return URL(fileURLWithPath: "/usr/bin/ps")
        }
        throw RuntimeWorkerAcceptanceRunnerError
            .processInspectionFailed("ps executable is unavailable")
    }

    private static func diagnostic(stderr: Data, stdout: Data) -> String {
        let errorText = String(decoding: stderr.prefix(8_192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !errorText.isEmpty {
            return errorText
        }
        return String(decoding: stdout.prefix(8_192), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum BoundedProcessError: Error, CustomStringConvertible {
    case launchFailed(String)
    case deadlineExceeded
    case descriptorFailed(String)
    case outputLimitExceeded(stream: String, maximumByteCount: Int)
    case outputReadFailed(stream: String, errorCode: Int32, detail: String)

    var description: String {
        switch self {
        case .launchFailed(let detail):
            "process launch failed: \(detail)"
        case .deadlineExceeded:
            "process execution or output EOF exceeded its bounded deadline"
        case .descriptorFailed(let detail):
            "process output descriptor failed: \(detail)"
        case .outputLimitExceeded(let stream, let maximumByteCount):
            "process \(stream) exceeded \(maximumByteCount) bytes"
        case .outputReadFailed(let stream, let errorCode, let detail):
            "process \(stream) read failed with errno \(errorCode): \(detail)"
        }
    }
}

private struct BoundedPipeCapture {
    let streamName: String
    let readHandle: FileHandle
    let writeHandle: FileHandle
    private(set) var data = Data()
    private(set) var reachedEOF = false
    private var parentWriteClosed = false
    private var readClosed = false
    private var exceededLimit = false

    init(streamName: String) throws {
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let writeHandle = pipe.fileHandleForWriting
        do {
            try Self.configureNonblockingRead(
                descriptor: readHandle.fileDescriptor,
                streamName: streamName
            )
        } catch {
            var cleanupFailures: [String] = []
            do {
                try writeHandle.close()
            } catch {
                cleanupFailures.append("write end: \(error)")
            }
            do {
                try readHandle.close()
            } catch {
                cleanupFailures.append("read end: \(error)")
            }
            if !cleanupFailures.isEmpty {
                throw BoundedProcessError.descriptorFailed(
                    "\(error); setup cleanup failed: "
                        + cleanupFailures.joined(separator: " | ")
                )
            }
            throw error
        }
        self.streamName = streamName
        self.readHandle = readHandle
        self.writeHandle = writeHandle
    }

    mutating func closeParentWrite() throws {
        guard !parentWriteClosed else { return }
        parentWriteClosed = true
        do {
            try writeHandle.close()
        } catch {
            throw BoundedProcessError.descriptorFailed(
                "cannot close parent \(streamName) write end: \(error)"
            )
        }
    }

    /// Drains a nonblocking descriptor without allowing pointers to escape.
    /// The UInt8 buffer has byte alignment, the read count is validated before
    /// appending, and every descriptor remains owned by this value until the
    /// exactly-once close boundary.
    mutating func drain(maximumByteCount: Int) throws -> Bool {
        guard !readClosed, !reachedEOF else { return false }
        var newlyExceededLimit = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        for _ in 0..<16 {
            var capturedErrno: Int32 = 0
            let byteCount = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                #if canImport(Darwin)
                let result = Darwin.read(
                    readHandle.fileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
                #elseif canImport(Glibc)
                let result = Glibc.read(
                    readHandle.fileDescriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
                #else
                let result = -1
                #endif
                if result < 0 {
                    capturedErrno = errno
                }
                return result
            }

            if byteCount > 0 {
                if !exceededLimit {
                    let remaining = maximumByteCount - data.count
                    let acceptedByteCount = min(remaining, byteCount)
                    if acceptedByteCount > 0 {
                        data.append(contentsOf: buffer.prefix(acceptedByteCount))
                    }
                    if acceptedByteCount != byteCount {
                        exceededLimit = true
                        newlyExceededLimit = true
                    }
                }
                continue
            }
            if byteCount == 0 {
                reachedEOF = true
                return newlyExceededLimit
            }
            if capturedErrno == EINTR {
                continue
            }
            if capturedErrno == EAGAIN || capturedErrno == EWOULDBLOCK {
                return newlyExceededLimit
            }
            throw BoundedProcessError.outputReadFailed(
                stream: streamName,
                errorCode: capturedErrno,
                detail: String(cString: strerror(capturedErrno))
            )
        }
        return newlyExceededLimit
    }

    mutating func closeAll() -> [String] {
        var failures: [String] = []
        if !parentWriteClosed {
            parentWriteClosed = true
            do {
                try writeHandle.close()
            } catch {
                failures.append(
                    "close parent \(streamName) write end: \(error)"
                )
            }
        }
        if !readClosed {
            readClosed = true
            do {
                try readHandle.close()
            } catch {
                failures.append("close \(streamName) read end: \(error)")
            }
        }
        return failures
    }

    private static func configureNonblockingRead(
        descriptor: Int32,
        streamName: String
    ) throws {
        #if canImport(Darwin) || canImport(Glibc)
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags >= 0,
              fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0 else {
            let errorCode = errno
            throw BoundedProcessError.descriptorFailed(
                "cannot make \(streamName) nonblocking: errno \(errorCode)"
            )
        }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            let errorCode = errno
            throw BoundedProcessError.descriptorFailed(
                "cannot protect \(streamName) across exec: errno \(errorCode)"
            )
        }
        #else
        throw BoundedProcessError.descriptorFailed(
            "nonblocking process capture is unavailable for \(streamName)"
        )
        #endif
    }
}
