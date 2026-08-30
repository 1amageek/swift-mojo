import Foundation
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Mojo runtime worker artifact admission")
struct MojoRuntimeWorkerArtifactAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func stagesPrivatelyAndSpawnsOnlyTheFreshVerifiedExecutable() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var spawnedExecutablePath: String?
        var spawnedArguments: [String]?
        var spawnedEnvironment: [String: String]?
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { stagedURL in
                try verifyFixtureTree(
                    at: stagedURL,
                    expected: fixture.expectedFiles
                )
                return MojoRuntimeWorkerTestFixture.rebased(
                    fixture.verification,
                    to: stagedURL
                )
            },
            spawn: { executablePath, arguments, environment in
                spawnedExecutablePath = executablePath
                spawnedArguments = arguments
                spawnedEnvironment = environment
                return try MojoPOSIXWorkerSupport.spawn(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment
                )
            },
            readStartup: { process, verification, timeout in
                try MojoRuntimeWorkerStartupReader.readReady(
                    from: process,
                    verification: verification,
                    timeout: timeout
                )
            }
        )

        let admitted = try admit(
            admission,
            verification: fixture.verification,
            timeout: .seconds(3)
        )
        defer { cleanup(admitted) }

        #expect(admitted.verification.verifiedBundleURL == admitted.stage.bundleURL)
        #expect(admitted.stage.bundleURL != fixture.bundleURL)
        #expect(
            spawnedExecutablePath
                == admitted.stage.bundleURL
                    .appendingPathComponent("bin/worker").path
        )
        #expect(spawnedArguments == [])
        #expect(spawnedEnvironment == [:])
        try MojoRuntimeWorkerArtifactAdmission.verifyPrivatePermissions(
            at: admitted.stage.rootURL
        )
        #expect(admitted.claimTerminalCleanup())
        #expect(!admitted.claimTerminalCleanup())
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsSourceCopyManifestAndTreeMutationBeforeSpawn() throws {
        for mutation in FixtureMutation.allCases {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            try mutation.mutateSource(fixture)
            var spawnCount = 0
            var stagedURL: URL?
            let admission = MojoRuntimeWorkerArtifactAdmission(
                fileManager: .default,
                verify: { copiedURL in
                    stagedURL = copiedURL
                    try mutation.mutateCopyIfNeeded(copiedURL)
                    try verifyFixtureTree(
                        at: copiedURL,
                        expected: fixture.expectedFiles
                    )
                    return MojoRuntimeWorkerTestFixture.rebased(
                        fixture.verification,
                        to: copiedURL
                    )
                },
                spawn: { _, _, _ in
                    spawnCount += 1
                    throw AdmissionTestFailure(
                        "Mutation unexpectedly reached spawn"
                    )
                },
                readStartup: { _, _, _ in
                    throw AdmissionTestFailure(
                        "Mutation unexpectedly reached startup"
                    )
                }
            )

            do {
                _ = try admit(
                    admission,
                    verification: fixture.verification,
                    timeout: .seconds(1)
                )
                Issue.record("\(mutation) unexpectedly admitted")
            } catch let error as MojoRuntimeWorkerError {
                guard case .stagedVerificationFailed = error else {
                    Issue.record("Unexpected \(mutation) error: \(error)")
                    continue
                }
            }
            #expect(spawnCount == 0)
            if let stagedURL {
                #expect(
                    !FileManager.default.fileExists(
                        atPath: stagedURL.deletingLastPathComponent().path
                    )
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func semanticProjectionDriftStopsBeforeSpawnAndRemovesTheStage() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var spawnCount = 0
        var stagedURL: URL?
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { copiedURL in
                stagedURL = copiedURL
                return MojoRuntimeWorkerTestFixture.rebased(
                    fixture.verification,
                    to: copiedURL,
                    bundleDigest: MojoRuntimeWorkerTestFixture.digest("0")
                )
            },
            spawn: { _, _, _ in
                spawnCount += 1
                throw AdmissionTestFailure(
                    "Projection drift unexpectedly reached spawn"
                )
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure(
                    "Projection drift unexpectedly reached startup"
                )
            }
        )

        #expect(throws: MojoRuntimeWorkerError.stagedProjectionMismatch) {
            try admit(
                admission,
                verification: fixture.verification,
                timeout: .seconds(1)
            )
        }
        #expect(spawnCount == 0)
        if let stagedURL {
            #expect(
                !FileManager.default.fileExists(
                    atPath: stagedURL.deletingLastPathComponent().path
                )
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func slowPrivateCopyExpiresBeforeFreshVerificationOrSpawn() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { removeIfPresent(stageRoot) }
        var verificationCount = 0
        var spawnCount = 0
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            copyItem: { sourceURL, destinationURL in
                Thread.sleep(forTimeInterval: 0.05)
                try FileManager.default.copyItem(
                    at: sourceURL,
                    to: destinationURL
                )
            },
            verify: { stagedURL in
                verificationCount += 1
                return MojoRuntimeWorkerTestFixture.rebased(
                    fixture.verification,
                    to: stagedURL
                )
            },
            spawn: { _, _, _ in
                spawnCount += 1
                throw AdmissionTestFailure("Expired copy reached spawn")
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure("Expired copy reached startup")
            },
            makeStageRoot: { stageRoot }
        )

        #expect(throws: MojoRuntimeWorkerError.startupTimedOut) {
            try admit(
                admission,
                verification: fixture.verification,
                timeout: .milliseconds(10)
            )
        }
        #expect(verificationCount == 0)
        #expect(spawnCount == 0)
        #expect(!FileManager.default.fileExists(atPath: stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func slowFreshVerificationExpiresBeforeSpawn() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { removeIfPresent(stageRoot) }
        var spawnCount = 0
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { stagedURL in
                Thread.sleep(forTimeInterval: 0.05)
                return MojoRuntimeWorkerTestFixture.rebased(
                    fixture.verification,
                    to: stagedURL
                )
            },
            spawn: { _, _, _ in
                spawnCount += 1
                throw AdmissionTestFailure(
                    "Expired fresh verification reached spawn"
                )
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure(
                    "Expired fresh verification reached startup"
                )
            },
            makeStageRoot: { stageRoot }
        )

        #expect(throws: MojoRuntimeWorkerError.startupTimedOut) {
            try admit(
                admission,
                verification: fixture.verification,
                timeout: .milliseconds(10)
            )
        }
        #expect(spawnCount == 0)
        #expect(!FileManager.default.fileExists(atPath: stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func readyMismatchRollsBackProcessDescriptorsAndPrivateStage() throws {
        let baseFixture = try makeFixture()
        defer { baseFixture.remove() }
        let mismatchedFrame = try mismatchedReadyFrame(
            for: baseFixture.verification
        )
        let fixture = try makeFixture(frameData: mismatchedFrame)
        defer { fixture.remove() }
        var process: MojoPOSIXWorkerProcess?
        var stagedURL: URL?
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { copiedURL in
                stagedURL = copiedURL
                return MojoRuntimeWorkerTestFixture.rebased(
                    fixture.verification,
                    to: copiedURL
                )
            },
            spawn: { executablePath, arguments, environment in
                let spawned = try MojoPOSIXWorkerSupport.spawn(
                    executablePath: executablePath,
                    arguments: arguments,
                    environment: environment
                )
                process = spawned
                return spawned
            },
            readStartup: { process, verification, timeout in
                try MojoRuntimeWorkerStartupReader.readReady(
                    from: process,
                    verification: verification,
                    timeout: timeout
                )
            }
        )

        #expect(
            throws: MojoRuntimeWorkerError.readyMismatch(
                field: "executionContractDigest"
            )
        ) {
            try admit(
                admission,
                verification: fixture.verification,
                timeout: .seconds(3)
            )
        }
        let spawned = try #require(process)
        #expect(!MojoPOSIXSupport.processGroupIsAlive(spawned.processID))
        do {
            _ = try MojoPOSIXSupport.waitNoHang(processID: spawned.processID)
            Issue.record("Rolled-back child was not reaped by its owner")
        } catch let error as MojoPOSIXSupportError {
            #expect(error == .childAlreadyReaped)
        }
        if let stagedURL {
            #expect(
                !FileManager.default.fileExists(
                    atPath: stagedURL.deletingLastPathComponent().path
                )
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func refusesANonPrivateStageRootAndEscapingExecutable() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        defer {
            do {
                try FileManager.default.removeItem(at: rootURL)
            } catch {
                Issue.record("Failed to remove permission fixture: \(error)")
            }
        }

        #expect(
            throws: MojoRuntimeWorkerError.privateStagePermissions(
                actual: 0o755
            )
        ) {
            try MojoRuntimeWorkerArtifactAdmission.verifyPrivatePermissions(
                at: rootURL
            )
        }

        let verification = verificationWithExecutable(
            "../outside",
            bundleURL: rootURL
        )
        #expect(throws: MojoRuntimeWorkerError.invalidExecutablePath) {
            try MojoRuntimeWorkerArtifactAdmission.verifiedExecutableURL(
                in: verification
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func retainsThePrivateStageUntilProcessLifetimeEnds() throws {
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: stageRoot,
            withIntermediateDirectories: false
        )
        defer {
            if FileManager.default.fileExists(atPath: stageRoot.path) {
                do {
                    try FileManager.default.removeItem(at: stageRoot)
                } catch {
                    Issue.record("Failed to remove retained stage: \(error)")
                }
            }
        }

        let retained = MojoRuntimeWorkerArtifactAdmission.finalizePrivateStage(
            at: stageRoot,
            processLifetimeEnded: false
        )
        #expect(retained == .privateStageRetained)
        #expect(FileManager.default.fileExists(atPath: stageRoot.path))

        let removed = MojoRuntimeWorkerArtifactAdmission.finalizePrivateStage(
            at: stageRoot,
            processLifetimeEnded: true
        )
        #expect(removed == nil)
        #expect(!FileManager.default.fileExists(atPath: stageRoot.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func absentPrivateStageIsTheOnlyRemovalErrorTreatedAsAlreadyClean() {
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        let result = MojoRuntimeWorkerArtifactAdmission.finalizePrivateStage(
            at: stageRoot,
            processLifetimeEnded: true
        )

        #expect(result == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func privateStageRemovalErrorCannotMasqueradeAsAnAbsentStage() {
        let stageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let expectedError = AdmissionTestFailure("stage removal denied")

        let result = MojoRuntimeWorkerArtifactAdmission.finalizePrivateStage(
            at: stageRoot,
            processLifetimeEnded: true,
            removeItem: { _ in throw expectedError }
        )

        #expect(result == .privateStageRemovalFailed)
    }

    @Test(.timeLimit(.minutes(1)))
    func preservesTypedPrimaryAndOrderedCleanupFailures() {
        let primary = MojoRuntimeWorkerError.readyMismatch(
            field: "executionContractDigest"
        )
        let error = MojoRuntimeWorkerError.cleanupFailed(
            primary: .worker(primary),
            failures: [
                .transportCloseFailed,
                .processReapFailed,
                .privateStageRetained,
            ]
        )

        guard case .cleanupFailed(
            primary: let observedPrimary,
            failures: let observedFailures
        ) = error else {
            Issue.record("Expected a structured cleanup failure")
            return
        }
        #expect(observedPrimary == .worker(primary))
        #expect(
            observedFailures == [
                .transportCloseFailed,
                .processReapFailed,
                .privateStageRetained,
            ]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func copyFailureDoesNotExposeTheSourceOrPrivateStagePath() throws {
        let fixture = try makeFixture()
        let sourcePath = fixture.bundleURL.path
        fixture.remove()
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { _ in
                throw AdmissionTestFailure("Verification must not run")
            },
            spawn: { _, _, _ in
                throw AdmissionTestFailure("Spawn must not run")
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure("Startup must not run")
            }
        )

        do {
            _ = try admit(
                admission,
                verification: fixture.verification,
                timeout: .seconds(1)
            )
            Issue.record("Missing source unexpectedly admitted")
        } catch let error as MojoRuntimeWorkerError {
            #expect(error == .privateStageCopyFailed)
            #expect(!String(describing: error).contains(sourcePath))
            #expect(!String(describing: error).contains("swift-mojo-worker-"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stageCreationFailureDoesNotDeleteAnUnownedCollision() throws {
        let collisionRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let markerURL = collisionRoot.appendingPathComponent("owner-marker")
        try FileManager.default.createDirectory(
            at: collisionRoot,
            withIntermediateDirectories: false
        )
        try Data("owned\n".utf8).write(to: markerURL)
        defer {
            do {
                try FileManager.default.removeItem(at: collisionRoot)
            } catch {
                Issue.record("Failed to remove collision fixture: \(error)")
            }
        }
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { _ in
                throw AdmissionTestFailure("Verification must not run")
            },
            spawn: { _, _, _ in
                throw AdmissionTestFailure("Spawn must not run")
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure("Startup must not run")
            },
            makeStageRoot: { collisionRoot }
        )

        #expect(throws: MojoRuntimeWorkerError.privateStageCreationFailed) {
            try admit(
                admission,
                verification: fixture.verification,
                timeout: .seconds(1)
            )
        }
        #expect(FileManager.default.fileExists(atPath: collisionRoot.path))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    private func admit(
        _ admission: MojoRuntimeWorkerArtifactAdmission,
        verification: MojoRuntimeWorkerBundleVerification,
        timeout: Duration
    ) throws -> MojoRuntimeWorkerAdmittedProcess {
        let clock = ContinuousClock()
        return try admission.admit(
            verification: verification,
            startupDeadline: clock.now.advanced(by: timeout),
            terminationGracePeriod: timeout,
            forcedCleanup: timeout
        )
    }

    private func makeFixture(
        frameData: Data? = nil
    ) throws -> WorkerBundleFixture {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = rootURL.appendingPathComponent(
            "selected.bundle",
            isDirectory: true
        )
        let binURL = bundleURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(
            at: binURL,
            withIntermediateDirectories: true
        )
        let provisional = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: bundleURL
        )
        let readyData = try frameData
            ?? MojoRuntimeWorkerTestFixture.readyFrameData(for: provisional)
        let script = """
        #!/bin/sh
        printf '\(MojoRuntimeWorkerTestFixture.shellOctal(readyData))' >&3
        while IFS= read -r line <&3; do :; done
        """
        let workerURL = binURL.appendingPathComponent("worker")
        try Data(script.utf8).write(to: workerURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: workerURL.path
        )
        let manifestURL = bundleURL.appendingPathComponent(
            "RuntimeWorkerBundle.json"
        )
        try Data("fixture-manifest-v1\n".utf8).write(to: manifestURL)
        let expectedFiles = [
            "RuntimeWorkerBundle.json": try Data(contentsOf: manifestURL),
            "bin/worker": try Data(contentsOf: workerURL),
        ]
        return WorkerBundleFixture(
            rootURL: rootURL,
            bundleURL: bundleURL,
            verification: provisional,
            expectedFiles: expectedFiles
        )
    }

    private func mismatchedReadyFrame(
        for verification: MojoRuntimeWorkerBundleVerification
    ) throws -> Data {
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes:
                verification.maximumFramePayloadBytes
        )
        let ready = try MojoRuntimeWorkerTestFixture.ready(
            for: verification,
            executionContractDigest:
                MojoRuntimeWorkerTestFixture.digest("0")
        )
        return try MojoRuntimeFrame(
            requestID: 0,
            payload: .ready(ready),
            limits: limits
        ).encodedData(limits: limits)
    }

    private func cleanup(_ admitted: MojoRuntimeWorkerAdmittedProcess) {
        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                admitted.process.protocolDescriptor
            )
        } catch {
            Issue.record("Failed to close admitted transport: \(error)")
        }
        do {
            if try MojoPOSIXSupport.waitNoHang(
                processID: admitted.process.processID
            ) == nil {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: admitted.process.processID,
                    signal: MojoPOSIXSupport.killSignal
                )
                let clock = ContinuousClock()
                let deadline = clock.now.advanced(by: .seconds(3))
                while clock.now < deadline {
                    if try MojoPOSIXSupport.waitNoHang(
                        processID: admitted.process.processID
                    ) != nil {
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
        } catch let error as MojoPOSIXSupportError {
            if error != .childAlreadyReaped {
                Issue.record("Failed to reap admitted worker: \(error)")
            }
        } catch {
            Issue.record("Failed to reap admitted worker: \(error)")
        }
        do {
            try MojoPOSIXWorkerSupport.closeDescriptor(
                admitted.process.diagnosticDescriptor
            )
        } catch {
            Issue.record("Failed to close admitted diagnostics: \(error)")
        }
        do {
            try FileManager.default.removeItem(at: admitted.stage.rootURL)
        } catch {
            Issue.record("Failed to remove admitted stage: \(error)")
        }
    }

    private func removeIfPresent(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Failed to remove deadline fixture: \(error)")
        }
    }

    private func verificationWithExecutable(
        _ relativePath: String,
        bundleURL: URL
    ) -> MojoRuntimeWorkerBundleVerification {
        let base = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: bundleURL
        )
        return MojoRuntimeWorkerBundleVerification(
            schemaVersion: base.schemaVersion,
            bundleDigest: base.bundleDigest,
            executionContractDigest: base.executionContractDigest,
            workerABIVersion: base.workerABIVersion,
            sourceGraphDigest: base.sourceGraphDigest,
            sourceGraphIdentifier: base.sourceGraphIdentifier,
            inputGraphDigest: base.inputGraphDigest,
            inputGraphIdentifier: base.inputGraphIdentifier,
            generationPipelineDigest: base.generationPipelineDigest,
            bindingTableDigest: base.bindingTableDigest,
            bindings: base.bindings,
            generatedMojoSourceDigest: base.generatedMojoSourceDigest,
            generatedCWorkerSourceDigest: base.generatedCWorkerSourceDigest,
            sourceMapDigest: base.sourceMapDigest,
            generatedMojoObjectDigest: base.generatedMojoObjectDigest,
            generatedCWorkerObjectDigest: base.generatedCWorkerObjectDigest,
            compilerVersion: base.compilerVersion,
            protocolVersion: base.protocolVersion,
            protocolDescriptor: base.protocolDescriptor,
            protocolHeaderByteCount: base.protocolHeaderByteCount,
            protocolByteOrder: base.protocolByteOrder,
            maximumFramePayloadBytes: base.maximumFramePayloadBytes,
            maximumInFlightRequests: base.maximumInFlightRequests,
            protocolMessageKinds: base.protocolMessageKinds,
            runtimeBundleManifestDigest: base.runtimeBundleManifestDigest,
            runtimeReceiptDigest: base.runtimeReceiptDigest,
            executable: MojoRuntimeBundleFile(
                relativePath: relativePath,
                sha256Digest: base.executable.sha256Digest
            ),
            libraries: base.libraries,
            loaderSearchPath: base.loaderSearchPath,
            systemDependencies: base.systemDependencies,
            programInterpreter: base.programInterpreter,
            target: base.target,
            artifactIdentity: base.artifactIdentity,
            targetClosureDigest: base.targetClosureDigest,
            verifiedBundleURL: bundleURL
        )
    }
}

private struct WorkerBundleFixture {
    let rootURL: URL
    let bundleURL: URL
    let verification: MojoRuntimeWorkerBundleVerification
    let expectedFiles: [String: Data]

    func remove() {
        do {
            try FileManager.default.removeItem(at: rootURL)
        } catch {
            Issue.record("Failed to remove worker fixture: \(error)")
        }
    }
}

private enum FixtureMutation: CaseIterable, CustomStringConvertible, Equatable {
    case sourceBytes
    case copiedBytes
    case manifest
    case extraEntry
    case missingEntry
    case symbolicLink

    var description: String {
        switch self {
        case .sourceBytes: "source byte mutation"
        case .copiedBytes: "copied byte mutation"
        case .manifest: "manifest mutation"
        case .extraEntry: "extra tree entry"
        case .missingEntry: "missing tree entry"
        case .symbolicLink: "symbolic link entry"
        }
    }

    func mutateSource(_ fixture: WorkerBundleFixture) throws {
        switch self {
        case .sourceBytes:
            try Data("changed-worker\n".utf8).write(
                to: fixture.bundleURL.appendingPathComponent("bin/worker")
            )
        case .manifest:
            try Data("changed-manifest\n".utf8).write(
                to: fixture.bundleURL.appendingPathComponent(
                    "RuntimeWorkerBundle.json"
                )
            )
        case .extraEntry:
            try Data("extra\n".utf8).write(
                to: fixture.bundleURL.appendingPathComponent("extra")
            )
        case .missingEntry:
            try FileManager.default.removeItem(
                at: fixture.bundleURL.appendingPathComponent(
                    "RuntimeWorkerBundle.json"
                )
            )
        case .symbolicLink:
            let manifestURL = fixture.bundleURL.appendingPathComponent(
                "RuntimeWorkerBundle.json"
            )
            try FileManager.default.removeItem(at: manifestURL)
            try FileManager.default.createSymbolicLink(
                at: manifestURL,
                withDestinationURL: fixture.bundleURL.appendingPathComponent(
                    "bin/worker"
                )
            )
        case .copiedBytes:
            break
        }
    }

    func mutateCopyIfNeeded(_ bundleURL: URL) throws {
        guard self == .copiedBytes else { return }
        try Data("changed-after-copy\n".utf8).write(
            to: bundleURL.appendingPathComponent("bin/worker")
        )
    }
}

private func verifyFixtureTree(
    at bundleURL: URL,
    expected: [String: Data]
) throws {
    let actualEntries = try regularAndSymbolicEntries(at: bundleURL)
    guard Set(actualEntries.keys) == Set(expected.keys) else {
        throw AdmissionTestFailure("fixture tree membership changed")
    }
    for (relativePath, expectedData) in expected {
        guard actualEntries[relativePath] == false else {
            throw AdmissionTestFailure(
                "fixture entry became a symbolic link"
            )
        }
        let actual = try Data(
            contentsOf: bundleURL.appendingPathComponent(relativePath)
        )
        guard actual == expectedData else {
            throw AdmissionTestFailure("fixture entry bytes changed")
        }
    }
}

private func regularAndSymbolicEntries(
    at rootURL: URL,
    prefix: String = ""
) throws -> [String: Bool] {
    var entries: [String: Bool] = [:]
    for childURL in try FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ],
        options: []
    ) {
        let relativePath = prefix.isEmpty
            ? childURL.lastPathComponent
            : "\(prefix)/\(childURL.lastPathComponent)"
        let values = try childURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        if values.isSymbolicLink == true {
            entries[relativePath] = true
        } else if values.isDirectory == true {
            entries.merge(
                try regularAndSymbolicEntries(
                    at: childURL,
                    prefix: relativePath
                )
            ) { first, _ in first }
        } else if values.isRegularFile == true {
            entries[relativePath] = false
        } else {
            throw AdmissionTestFailure(
                "fixture contains an unsupported entry"
            )
        }
    }
    return entries
}

private struct AdmissionTestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}
