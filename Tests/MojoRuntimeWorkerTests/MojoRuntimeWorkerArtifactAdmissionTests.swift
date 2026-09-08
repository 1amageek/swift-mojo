import Foundation
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Mojo runtime worker artifact admission", .serialized)
struct MojoRuntimeWorkerArtifactAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func resourceAdmissionCopiesIdentityBeforeSpawnAndRollsBackFailures() throws {
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        for variant in ["valid", "missing", "link", "directory", "size", "digest"] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let source = fixture.rootURL.appendingPathComponent("model")
            switch variant {
            case "missing": break
            case "directory":
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            case "link":
                let target = fixture.rootURL.appendingPathComponent("target")
                try Data("abc".utf8).write(to: target)
                try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
            default:
                try Data("abc".utf8).write(to: source)
            }
            let identifier = try MojoRuntimeWorkerInputResourceID("model")
            let resource = try MojoRuntimeWorkerInputResource(
                identifier: identifier,
                fileURL: source,
                expectedByteCount: variant == "size" ? 4 : 3,
                expectedSHA256: variant == "digest" ? String(repeating: "0", count: 64) : digest
            )
            let limits = try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 1,
                maximumAggregateByteCount: 4
            )
            let inputResources = try MojoRuntimeWorkerInputResources(
                resources: [resource], limits: limits
            )
            let stageRoot = fixture.rootURL.appendingPathComponent("attempt", isDirectory: true)
            var spawnCount = 0
            let admission = MojoRuntimeWorkerArtifactAdmission(
                fileManager: .default,
                verify: { MojoRuntimeWorkerTestFixture.rebased(fixture.verification, to: $0) },
                spawn: { executable, arguments, environment in
                    spawnCount += 1
                    let environment = try #require(environment)
                    #expect(Set(environment.keys) == [
                        "SWIFT_MOJO_INPUT_RESOURCE_DIRECTORY",
                        "SWIFT_MOJO_INPUT_RESOURCE_COUNT",
                        "SWIFT_MOJO_INPUT_RESOURCE_BYTES",
                        "SWIFT_MOJO_INPUT_RESOURCE_SHA256",
                        "SWIFT_MOJO_RUNTIME_LIBRARY_DIRECTORY"
                    ])
                    let directory = URL(fileURLWithPath: try #require(
                        environment["SWIFT_MOJO_INPUT_RESOURCE_DIRECTORY"]
                    ))
                    #expect(directory == stageRoot.appendingPathComponent(
                        "input-resources", isDirectory: true
                    ))
                    #expect(environment["SWIFT_MOJO_INPUT_RESOURCE_COUNT"] == "1")
                    #expect(environment["SWIFT_MOJO_INPUT_RESOURCE_BYTES"] == "3")
                    #expect(environment["SWIFT_MOJO_INPUT_RESOURCE_SHA256"] == inputResources.aggregateSHA256)
                    let staged = directory.appendingPathComponent("model")
                    #expect(staged != source)
                    #expect(try Data(contentsOf: staged) == Data("abc".utf8))
                    let attributes = try FileManager.default.attributesOfItem(atPath: staged.path)
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
                    #expect(environment["SWIFT_MOJO_RUNTIME_LIBRARY_DIRECTORY"] ==
                        stageRoot.appendingPathComponent("bundle/lib").path)
                    return try MojoPOSIXWorkerSupport.spawn(
                        executablePath: executable, arguments: arguments, environment: environment
                    )
                },
                readStartup: { process, verification, timeout in
                    try MojoRuntimeWorkerStartupReader.readReady(
                        from: process, verification: verification, timeout: timeout
                    )
                },
                makeStageRoot: { stageRoot }
            )
            do {
                let admitted = try admission.admit(
                    verification: fixture.verification, inputResources: inputResources,
                    startupDeadline: ContinuousClock.now.advanced(by: .seconds(3)),
                    terminationGracePeriod: .seconds(1), forcedCleanup: .seconds(3)
                )
                #expect(variant == "valid")
                cleanup(admitted)
            } catch let error as MojoRuntimeWorkerError {
                switch variant {
                case "missing", "link", "directory": #expect(error == .inputResourceUnavailable)
                case "size": #expect(error == .inputResourceByteCountMismatch)
                case "digest": #expect(error == .inputResourceDigestMismatch)
                default: Issue.record("Valid resource failed: \(error)")
                }
            }
            #expect(spawnCount == (variant == "valid" ? 1 : 0))
            #expect(!FileManager.default.fileExists(atPath: stageRoot.path))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inputResourceRequiresExactIdentity() throws {
        let url = URL(fileURLWithPath: "/unused")
        let digest = String(repeating: "a", count: 64)
        for (count, hash) in [(Int64(0), digest), (-1, digest), (1, "bad"), (1, digest.uppercased())] {
            #expect(throws: MojoRuntimeWorkerError.invalidInputResourceIdentity) {
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("model"),
                    fileURL: url, expectedByteCount: count, expectedSHA256: hash
                )
            }
        }
        #expect(throws: MojoRuntimeWorkerError.invalidInputResourceIdentity) {
            try MojoRuntimeWorkerInputResource(
                identifier: try MojoRuntimeWorkerInputResourceID("model"),
                fileURL: URL(string: "https://example.com/model")!,
                expectedByteCount: 1, expectedSHA256: digest
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func inputResourceSetRequiresBoundsAndStableIdentity() throws {
        let first = try MojoRuntimeWorkerInputResource(
            identifier: try MojoRuntimeWorkerInputResourceID("first"),
            fileURL: URL(fileURLWithPath: "/unused-first"),
            expectedByteCount: 1,
            expectedSHA256: String(repeating: "a", count: 64)
        )
        let second = try MojoRuntimeWorkerInputResource(
            identifier: try MojoRuntimeWorkerInputResourceID("second"),
            fileURL: URL(fileURLWithPath: "/unused-second"),
            expectedByteCount: 2,
            expectedSHA256: String(repeating: "b", count: 64)
        )
        let limits = try MojoRuntimeWorkerInputResourceLimits(
            maximumResourceCount: 2,
            maximumAggregateByteCount: 3
        )
        let ordered = try MojoRuntimeWorkerInputResources(
            resources: [first, second], limits: limits
        )
        let reversed = try MojoRuntimeWorkerInputResources(
            resources: [second, first], limits: limits
        )
        #expect(ordered.count == 2)
        #expect(ordered.aggregateByteCount == 3)
        #expect(
            ordered.aggregateSHA256
                == "3a09b5dad8b4153501c5d7dc91f9cd9b15abdd830e9f6f08d567d739aca9b224"
        )
        #expect(ordered.aggregateSHA256 == reversed.aggregateSHA256)

        let large = try MojoRuntimeWorkerInputResource(
            identifier: try MojoRuntimeWorkerInputResourceID("large"),
            fileURL: URL(fileURLWithPath: "/unused-large"),
            expectedByteCount: Int64.max - 3,
            expectedSHA256: String(repeating: "c", count: 64)
        )
        let explicitLimits = try MojoRuntimeWorkerInputResourceLimits(
            maximumResourceCount: 3, maximumAggregateByteCount: Int64.max
        )
        let largeSet = try MojoRuntimeWorkerInputResources(
            resources: [first, second, large], limits: explicitLimits
        )
        #expect(largeSet.count == 3)
        #expect(largeSet.aggregateByteCount == Int64.max)
        let extra = try MojoRuntimeWorkerInputResource(
            identifier: try MojoRuntimeWorkerInputResourceID("extra"),
            fileURL: URL(fileURLWithPath: "/unused-extra"),
            expectedByteCount: 4,
            expectedSHA256: String(repeating: "d", count: 64)
        )
        #expect(throws: MojoRuntimeWorkerError.inputResourceAggregateByteCountLimitExceeded) {
            _ = try MojoRuntimeWorkerInputResources(
                resources: [large, extra], limits: explicitLimits
            )
        }

        #expect(throws: MojoRuntimeWorkerError.emptyInputResources) {
            try MojoRuntimeWorkerInputResources(resources: [], limits: limits)
        }
        #expect(throws: MojoRuntimeWorkerError.duplicateInputResourceIdentifier) {
            try MojoRuntimeWorkerInputResources(
                resources: [first, first], limits: limits
            )
        }
        #expect(throws: MojoRuntimeWorkerError.inputResourceCountLimitExceeded) {
            let countLimit = try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 1, maximumAggregateByteCount: 3
            )
            _ = try MojoRuntimeWorkerInputResources(
                resources: [first, second], limits: countLimit
            )
        }
        #expect(throws: MojoRuntimeWorkerError.inputResourceAggregateByteCountLimitExceeded) {
            let byteLimit = try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 2, maximumAggregateByteCount: 2
            )
            _ = try MojoRuntimeWorkerInputResources(
                resources: [first, second], limits: byteLimit
            )
        }
        #expect(throws: MojoRuntimeWorkerError.invalidInputResourceLimits) {
            try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 0, maximumAggregateByteCount: 1
            )
        }
        for invalid in ["", ".", "..", "a/b", "a\0b", "日本語", String(repeating: "a", count: 129)] {
            #expect(throws: MojoRuntimeWorkerError.invalidInputResourceIdentifier) {
                try MojoRuntimeWorkerInputResourceID(invalid)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func resourceAdmissionStagesMultipleMembersAndFixedMetadata() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstURL = fixture.rootURL.appendingPathComponent("first")
        let secondURL = fixture.rootURL.appendingPathComponent("second")
        try Data("abc".utf8).write(to: firstURL)
        try Data("abc".utf8).write(to: secondURL)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let resources = try MojoRuntimeWorkerInputResources(
            resources: [
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("z-model"),
                    fileURL: secondURL, expectedByteCount: 3, expectedSHA256: digest
                ),
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("a-model"),
                    fileURL: firstURL, expectedByteCount: 3, expectedSHA256: digest
                ),
            ],
            limits: try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 2, maximumAggregateByteCount: 6
            )
        )
        let stageRoot = fixture.rootURL.appendingPathComponent("attempt", isDirectory: true)
        var observedEnvironment: [String: String]?
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { MojoRuntimeWorkerTestFixture.rebased(fixture.verification, to: $0) },
            spawn: { executable, arguments, environment in
                guard let environment else {
                    throw AdmissionTestFailure("Resource environment was omitted")
                }
                observedEnvironment = environment
                let directory = URL(fileURLWithPath: try #require(
                    environment[MojoRuntimeWorkerInputResources.directoryEnvironmentKey]
                ))
                #expect(directory == stageRoot.appendingPathComponent(
                    "input-resources", isDirectory: true
                ))
                let directoryAttributes = try FileManager.default.attributesOfItem(
                    atPath: directory.path
                )
                #expect(
                    (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue
                        == 0o700
                )
                let names = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: []
                ).map(\.lastPathComponent).sorted()
                #expect(names == ["a-model", "z-model"])
                #expect(environment[MojoRuntimeWorkerInputResources.countEnvironmentKey] == "2")
                #expect(environment[MojoRuntimeWorkerInputResources.bytesEnvironmentKey] == "6")
                #expect(environment[MojoRuntimeWorkerInputResources.sha256EnvironmentKey] == resources.aggregateSHA256)
                for name in names {
                    let attributes = try FileManager.default.attributesOfItem(
                        atPath: directory.appendingPathComponent(name).path
                    )
                    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o400)
                }
                return try MojoPOSIXWorkerSupport.spawn(
                    executablePath: executable, arguments: arguments, environment: environment
                )
            },
            readStartup: { process, verification, timeout in
                try MojoRuntimeWorkerStartupReader.readReady(
                    from: process, verification: verification, timeout: timeout
                )
            },
            makeStageRoot: { stageRoot }
        )
        let admitted = try admission.admit(
            verification: fixture.verification, inputResources: resources,
            startupDeadline: ContinuousClock.now.advanced(by: .seconds(3)),
            terminationGracePeriod: .seconds(1), forcedCleanup: .seconds(3)
        )
        cleanup(admitted)
        #expect(observedEnvironment?.count == 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func secondResourceFailureRollsBackEarlierStagedMembersBeforeSpawn() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let firstURL = fixture.rootURL.appendingPathComponent("first")
        try Data("abc".utf8).write(to: firstURL)
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let resources = try MojoRuntimeWorkerInputResources(
            resources: [
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("first"),
                    fileURL: firstURL, expectedByteCount: 3, expectedSHA256: digest
                ),
                try MojoRuntimeWorkerInputResource(
                    identifier: try MojoRuntimeWorkerInputResourceID("second"),
                    fileURL: fixture.rootURL.appendingPathComponent("missing"),
                    expectedByteCount: 3, expectedSHA256: digest
                ),
            ],
            limits: try MojoRuntimeWorkerInputResourceLimits(
                maximumResourceCount: 2, maximumAggregateByteCount: 6
            )
        )
        let stageRoot = fixture.rootURL.appendingPathComponent("attempt", isDirectory: true)
        var spawnCount = 0
        let admission = MojoRuntimeWorkerArtifactAdmission(
            fileManager: .default,
            verify: { MojoRuntimeWorkerTestFixture.rebased(fixture.verification, to: $0) },
            spawn: { _, _, _ in
                spawnCount += 1
                throw AdmissionTestFailure("Second-resource failure unexpectedly reached spawn")
            },
            readStartup: { _, _, _ in
                throw AdmissionTestFailure("Second-resource failure unexpectedly reached startup")
            },
            makeStageRoot: { stageRoot }
        )
        #expect(throws: MojoRuntimeWorkerError.inputResourceUnavailable) {
            try admission.admit(
                verification: fixture.verification, inputResources: resources,
                startupDeadline: ContinuousClock.now.advanced(by: .seconds(3)),
                terminationGracePeriod: .seconds(1), forcedCleanup: .seconds(3)
            )
        }
        #expect(spawnCount == 0)
        #expect(!FileManager.default.fileExists(atPath: stageRoot.path))
    }

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
