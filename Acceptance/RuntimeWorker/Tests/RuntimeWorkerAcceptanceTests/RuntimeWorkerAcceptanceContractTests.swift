import Foundation
import RuntimeWorkerAcceptance
import Testing

@Suite("Runtime worker acceptance contract")
struct RuntimeWorkerAcceptanceContractTests {
    @Test(.timeLimit(.minutes(1)))
    func passedReceiptRoundTripsAsCanonicalBytes() throws {
        let receipt = try ReceiptFixture.passed()
        let encoded = try receipt.encoded()
        let decoded = try RuntimeWorkerAcceptanceContract.decodeCanonical(
            encoded
        )

        #expect(decoded == receipt)
        #expect(try decoded.encoded() == encoded)
        #expect(String(decoding: encoded, as: UTF8.self).contains("\"failure\":null"))
    }

    @Test(.timeLimit(.minutes(1)))
    func publicReceiptExposesOnlyCanonicalCodecMethods() throws {
        let receipt = try ReceiptFixture.passed()

        // An external consumer must not be able to bypass the canonical codec
        // with JSONEncoder or JSONDecoder on the public receipt type.
        #expect(!((receipt as Any) is any Encodable))
        #expect(!((receipt as Any) is any Decodable))

        let encoded = try receipt.encoded()
        #expect(
            try RuntimeWorkerAcceptanceContract.decodeCanonical(encoded)
                == receipt
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func emitsOnlyTheClosedTopLevelKeySet() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let expected: Set<String> = [
            "schemaVersion",
            "status",
            "evidenceScope",
            "claims",
            "swiftMojoRevision",
            "acceptanceSourceDigest",
            "host",
            "artifact",
            "protocol",
            "consumerBoundary",
            "executionEnvironment",
            "lifecycle",
            "failure",
        ]

        #expect(Set(object.keys) == expected)
        #expect(object["evidenceScope"] as? String == "actualHostProcessProtocol")
    }

    @Test(.timeLimit(.minutes(1)))
    func failedReceiptPreservesTypedFailureAndPartialObservations() throws {
        let receipt = try ReceiptFixture.failed()
        let encoded = try receipt.encoded()
        let decoded = try RuntimeWorkerAcceptanceContract.decodeCanonical(
            encoded
        )

        #expect(decoded == receipt)
        #expect(decoded.status == .failed)
        #expect(decoded.failure?.code == .protocolObservationMissing)
        #expect(decoded.lifecycle.nonEmptyInvocationInputElementCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func protocolRecordUsesTheIndependentSchemaOneOracle() throws {
        let record = try ReceiptFixture.protocolRecord()
        let expectedKinds = [
            "1:ready",
            "2:createSession",
            "3:sessionCreated",
            "4:invokeFloat32",
            "5:invocationResult",
            "6:shutdownSession",
            "7:sessionShutdown",
            "8:shutdownWorker",
            "9:workerShutdown",
            "10:failure",
        ]

        #expect(record.version == 1)
        #expect(record.descriptor == 3)
        #expect(record.headerByteCount == 32)
        #expect(record.byteOrder == "little-endian")
        #expect(record.maximumFramePayloadBytes == 65_536)
        #expect(record.maximumInFlightRequests == 1)
        #expect(
            record.messageKinds.map { "\($0.rawValue):\($0.name)" }
                == expectedKinds
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnknownAndMissingTopLevelKeys() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let withUnknownKey = Data(
            (text.dropLast() + ",\"unknown\":true}").utf8
        )
        let withoutFailure = Data(
            text.replacingOccurrences(of: ",\"failure\":null", with: "").utf8
        )

        expectContractFailure(withUnknownKey)
        expectContractFailure(withoutFailure)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnknownAndMissingNestedKeys() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let mutations: [(String, Data, Data)] = [
            (
                "claims",
                mutation(
                    text,
                    replacing: "\"performance\":false",
                    with: "\"performance\":false,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"performance\":false,",
                    with: ""
                )
            ),
            (
                "host",
                mutation(
                    text,
                    replacing: "\"cpu\":\"apple-m4\"",
                    with: "\"cpu\":\"apple-m4\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"cpu\":\"apple-m4\",",
                    with: ""
                )
            ),
            (
                "artifact",
                mutation(
                    text,
                    replacing: "\"bundleDigest\":\"\(ReceiptFixture.digest(0))\"",
                    with: "\"bundleDigest\":\"\(ReceiptFixture.digest(0))\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"bundleDigest\":\"\(ReceiptFixture.digest(0))\",",
                    with: ""
                )
            ),
            (
                "semanticIdentity",
                mutation(
                    text,
                    replacing: "\"workerABIVersion\":1",
                    with: "\"workerABIVersion\":1,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"workerABIVersion\":1",
                    with: ""
                )
            ),
            (
                "generatedInputs",
                mutation(
                    text,
                    replacing: "\"compilerVersion\":\"mojo 1.0\"",
                    with: "\"compilerVersion\":\"mojo 1.0\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"compilerVersion\":\"mojo 1.0\",",
                    with: ""
                )
            ),
            (
                "runtimeBundle",
                mutation(
                    text,
                    replacing: "\"loaderSearchPath\":\"lib\"",
                    with: "\"loaderSearchPath\":\"lib\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"loaderSearchPath\":\"lib\",",
                    with: ""
                )
            ),
            (
                "targetClosure",
                mutation(
                    text,
                    replacing: "\"targetAccelerator\":\"metal\"",
                    with: "\"targetAccelerator\":\"metal\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"targetAccelerator\":\"metal\",",
                    with: ""
                )
            ),
            (
                "protocol",
                mutation(
                    text,
                    replacing: "\"byteOrder\":\"little-endian\"",
                    with: "\"byteOrder\":\"little-endian\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"byteOrder\":\"little-endian\",",
                    with: ""
                )
            ),
            (
                "consumerBoundary",
                mutation(
                    text,
                    replacing: "\"rawPOSIXImports\":false",
                    with: "\"rawPOSIXImports\":false,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"rawPOSIXImports\":false,",
                    with: ""
                )
            ),
            (
                "executionEnvironment",
                mutation(
                    text,
                    replacing: "\"cleanEnvironmentObserved\":true",
                    with: "\"cleanEnvironmentObserved\":true,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"cleanEnvironmentObserved\":true,",
                    with: ""
                )
            ),
            (
                "lifecycle",
                mutation(
                    text,
                    replacing: "\"cleanNextAttemptObserved\":true",
                    with: "\"cleanNextAttemptObserved\":true,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"cleanNextAttemptObserved\":true,",
                    with: ""
                )
            ),
        ]

        for (category, unknown, missing) in mutations {
            expectContractFailure(unknown, context: "\(category) unknown key")
            expectContractFailure(missing, context: "\(category) missing key")
        }

        let deepMutations: [(String, Data, Data)] = [
            (
                "binding",
                mutation(
                    text,
                    replacing: "\"sessionFactoryFunctionName\":null",
                    with: "\"sessionFactoryFunctionName\":null,\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"sessionFactoryFunctionName\":null,",
                    with: ""
                )
            ),
            (
                "file",
                mutation(
                    text,
                    replacing: "\"relativePath\":\"bin/manas-worker\"",
                    with: "\"relativePath\":\"bin/manas-worker\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"relativePath\":\"bin/manas-worker\",",
                    with: ""
                )
            ),
            (
                "artifactIdentity",
                mutation(
                    text,
                    replacing: "\"targetName\":\"ManasRuntime\"",
                    with: "\"targetName\":\"ManasRuntime\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"targetName\":\"ManasRuntime\"",
                    with: ""
                )
            ),
            (
                "messageKind",
                mutation(
                    text,
                    replacing: "\"name\":\"ready\"",
                    with: "\"name\":\"ready\",\"unknown\":true"
                ),
                mutation(
                    text,
                    replacing: "\"name\":\"ready\",",
                    with: ""
                )
            ),
        ]

        for (category, unknown, missing) in deepMutations {
            expectContractFailure(unknown, context: "\(category) unknown key")
            expectContractFailure(missing, context: "\(category) missing key")
        }

        let failedText = String(
            decoding: try ReceiptFixture.failed().encoded(),
            as: UTF8.self
        )
        let failureUnknown = mutation(
            failedText,
            replacing: "\"message\":\"protocol exchange did not complete\"",
            with: "\"message\":\"protocol exchange did not complete\",\"unknown\":true"
        )
        let failureMissing = mutation(
            failedText,
            replacing: "\"message\":\"protocol exchange did not complete\"",
            with: ""
        )
        expectContractFailure(failureUnknown, context: "failure unknown key")
        expectContractFailure(failureMissing, context: "failure missing key")
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNonCanonicalWhitespaceAndDuplicateKeys() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let withWhitespace = Data((text + "\n").utf8)
        let withDuplicateKey = Data(
            (text.dropLast() + ",\"status\":\"passed\"}").utf8
        )
        let withReorderedNestedKeys = mutation(
            text,
            replacing: "\"name\":\"ready\",\"rawValue\":1",
            with: "\"rawValue\":1,\"name\":\"ready\""
        )

        expectContractFailure(withWhitespace)
        expectContractFailure(withDuplicateKey)
        expectContractFailure(withReorderedNestedKeys)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsPassWithoutCausallyValidHostObservations() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let noNativeWithoutProcess = String(
            decoding: mutation(
                text,
                replacing: "\"nativeTargetObserved\":true",
                with: "\"nativeTargetObserved\":false"
            ),
            as: UTF8.self
        )
        let noNativeText = String(
            decoding: mutation(
                noNativeWithoutProcess,
                replacing: "\"processLaunchObserved\":true",
                with: "\"processLaunchObserved\":false"
            ),
            as: UTF8.self
        )
        let noNativeTarget = mutation(
            noNativeText,
            replacing: "\"protocolExchangeObserved\":true",
            with: "\"protocolExchangeObserved\":false"
        )
        let noProcessText = String(
            decoding: mutation(
                text,
                replacing: "\"processLaunchObserved\":true",
                with: "\"processLaunchObserved\":false"
            ),
            as: UTF8.self
        )
        let noProcess = mutation(
            noProcessText,
            replacing: "\"protocolExchangeObserved\":true",
            with: "\"protocolExchangeObserved\":false"
        )
        let noProtocol = mutation(
            text,
            replacing: "\"protocolExchangeObserved\":true",
            with: "\"protocolExchangeObserved\":false"
        )

        expectContractFailureContaining(
            noNativeTarget,
            "a passed receipt requires actual host process and protocol observations",
            context: "native target, process, and protocol are absent"
        )
        expectContractFailureContaining(
            noProcess,
            "a passed receipt requires actual host process and protocol observations",
            context: "process and protocol are absent"
        )
        expectContractFailureContaining(
            noProtocol,
            "a passed receipt requires actual host process and protocol observations",
            context: "protocol exchange is absent"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMutatedFixedClaimAndProtocolLimit() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let claimMutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(of: "\"maxDevice\":false", with: "\"maxDevice\":true")
                .utf8
        )
        let protocolMutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"maximumInFlightRequests\":1",
                    with: "\"maximumInFlightRequests\":2"
                )
                .utf8
        )

        expectContractFailure(claimMutation)
        expectContractFailure(protocolMutation)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMalformedArtifactAndBoundaryEvidence() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let artifactMutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"generatedMojoSourceDigest\":\"\(ReceiptFixture.digest(6))\"",
                    with: "\"generatedMojoSourceDigest\":\"invalid\""
                )
                .utf8
        )
        let boundaryMutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"rawPOSIXImports\":false",
                    with: "\"rawPOSIXImports\":true"
                )
                .utf8
        )

        expectContractFailure(artifactMutation)
        expectContractFailure(boundaryMutation)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsDirtyEnvironmentAndEveryNonPublicBoundary() throws {
        let text = String(
            decoding: try ReceiptFixture.passed().encoded(),
            as: UTF8.self
        )
        let environmentMutations = [
            mutation(
                text,
                replacing: "\"compilerAvailableDuringExecution\":false",
                with: "\"compilerAvailableDuringExecution\":true"
            ),
            mutation(
                text,
                replacing: "\"pythonAvailableDuringExecution\":false",
                with: "\"pythonAvailableDuringExecution\":true"
            ),
            mutation(
                text,
                replacing: "\"ambientLoaderVariableNames\":[]",
                with: "\"ambientLoaderVariableNames\":[\"DYLD_LIBRARY_PATH\"]"
            ),
            mutation(
                text,
                replacing: "\"cleanEnvironmentObserved\":true",
                with: "\"cleanEnvironmentObserved\":false"
            ),
        ]
        for value in environmentMutations {
            expectContractFailure(value, context: "dirty execution environment")
        }

        let boundaryMutations = [
            mutation(
                text,
                replacing: "\"publicRuntimeProjectionUsed\":true",
                with: "\"publicRuntimeProjectionUsed\":false"
            ),
            mutation(
                text,
                replacing: "\"publicWorkerAPIUsed\":true",
                with: "\"publicWorkerAPIUsed\":false"
            ),
            mutation(
                text,
                replacing: "\"filesystemAccessOutsideWorker\":false",
                with: "\"filesystemAccessOutsideWorker\":true"
            ),
            mutation(
                text,
                replacing: "\"processLaunchOutsideWorker\":false",
                with: "\"processLaunchOutsideWorker\":true"
            ),
            mutation(
                text,
                replacing: "\"runtimeLoaderOutsideWorker\":false",
                with: "\"runtimeLoaderOutsideWorker\":true"
            ),
            mutation(
                text,
                replacing: "\"rawPOSIXImports\":false",
                with: "\"rawPOSIXImports\":true"
            ),
            mutation(
                text,
                replacing: "\"rawProtocolImports\":false",
                with: "\"rawProtocolImports\":true"
            ),
            mutation(
                text,
                replacing: "\"workerSPIImports\":false",
                with: "\"workerSPIImports\":true"
            ),
        ]
        for value in boundaryMutations {
            expectContractFailure(value, context: "non-public consumer boundary")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNonCanonicalNestedOrderingAndLifecycleEvidence() throws {
        #expect(throws: RuntimeWorkerAcceptanceError.self) {
            _ = try RuntimeWorkerAcceptanceContract.Artifact.SemanticIdentity(
                workerABIVersion: 1,
                protocolVersion: 1,
                sourceGraphDigest: ReceiptFixture.digest(2),
                sourceGraphIdentifier: 1,
                inputGraphDigest: ReceiptFixture.digest(3),
                inputGraphIdentifier: 2,
                generationPipelineDigest: ReceiptFixture.digest(4),
                bindingTableDigest: ReceiptFixture.digest(5),
                bindings: [
                    try ReceiptFixture.sessionBinding,
                    try ReceiptFixture.factoryBinding,
                ]
            )
        }
        #expect(throws: RuntimeWorkerAcceptanceError.self) {
            let missingFactory = try RuntimeWorkerAcceptanceContract.Artifact.Binding(
                bindingID: 2,
                functionName: "invokeFloat32",
                signature: .sessionBorrowedMutableFloat32Buffers,
                sessionFactoryFunctionName: "missingFactory"
            )
            _ = try RuntimeWorkerAcceptanceContract.Artifact.SemanticIdentity(
                workerABIVersion: 1,
                protocolVersion: 1,
                sourceGraphDigest: ReceiptFixture.digest(2),
                sourceGraphIdentifier: 1,
                inputGraphDigest: ReceiptFixture.digest(3),
                inputGraphIdentifier: 2,
                generationPipelineDigest: ReceiptFixture.digest(4),
                bindingTableDigest: ReceiptFixture.digest(5),
                bindings: [try ReceiptFixture.factoryBinding, missingFactory]
            )
        }

        let encoded = try ReceiptFixture.passed().encoded()
        let mutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"forcedFailurePartialOutputElementCount\":0",
                    with: "\"forcedFailurePartialOutputElementCount\":1"
                )
                .utf8
        )
        expectContractFailure(mutation)
    }
}

private enum ReceiptFixture {
    static let targetTriple = "arm64-apple-macosx15.0"
    static let targetCPU = "apple-m4"
    static let revision = String(repeating: "a", count: 40)

    static func digest(_ value: Int) -> String {
        let digits = Array("0123456789abcdef")
        return String(
            (0..<64).map { digits[(value + $0) % digits.count] }
        )
    }

    static var factoryBinding: RuntimeWorkerAcceptanceContract.Artifact.Binding {
        get throws {
            try .init(
                bindingID: 1,
                functionName: "makeSession",
                signature: .runtimeSessionFactory,
                sessionFactoryFunctionName: nil
            )
        }
    }

    static var sessionBinding: RuntimeWorkerAcceptanceContract.Artifact.Binding {
        get throws {
            try .init(
                bindingID: 2,
                functionName: "invokeFloat32",
                signature: .sessionBorrowedMutableFloat32Buffers,
                sessionFactoryFunctionName: "makeSession"
            )
        }
    }

    static func host(
        allObserved: Bool
    ) throws -> RuntimeWorkerAcceptanceContract.Host {
        try RuntimeWorkerAcceptanceContract.Host(
            platform: .macOS,
            architecture: "arm64",
            targetTriple: targetTriple,
            cpu: targetCPU,
            nativeTargetObserved: allObserved,
            processLaunchObserved: allObserved,
            protocolExchangeObserved: allObserved
        )
    }

    static func artifact() throws
        -> RuntimeWorkerAcceptanceContract.Artifact
    {
        let identity = try RuntimeWorkerAcceptanceContract.Artifact.ArtifactIdentity(
            targetName: "ManasRuntime",
            moduleName: "ManasMojoRuntime",
            artifactName: "ManasMojoRuntime",
            libraryName: "libManasMojoRuntime.a",
            symbolPrefix: "manas_"
        )
        let target = try RuntimeWorkerAcceptanceContract.Artifact.TargetClosure(
            targetTriple: targetTriple,
            targetCPU: targetCPU,
            targetAccelerator: "metal",
            artifactIdentity: identity,
            targetClosureDigest: digest(15)
        )
        let semantic = try RuntimeWorkerAcceptanceContract.Artifact.SemanticIdentity(
            workerABIVersion: 1,
            protocolVersion: 1,
            sourceGraphDigest: digest(2),
            sourceGraphIdentifier: 1,
            inputGraphDigest: digest(3),
            inputGraphIdentifier: 2,
            generationPipelineDigest: digest(4),
            bindingTableDigest: digest(5),
            bindings: [try factoryBinding, try sessionBinding]
        )
        let generated = try RuntimeWorkerAcceptanceContract.Artifact.GeneratedInputs(
            generatedMojoSourceDigest: digest(6),
            generatedCWorkerSourceDigest: digest(7),
            sourceMapDigest: digest(8),
            generatedMojoObjectDigest: digest(9),
            generatedCWorkerObjectDigest: digest(10),
            compilerVersion: "mojo 1.0"
        )
        let executable = try RuntimeWorkerAcceptanceContract.Artifact.File(
            relativePath: "bin/manas-worker",
            sha256Digest: digest(11)
        )
        let library = try RuntimeWorkerAcceptanceContract.Artifact.File(
            relativePath: "lib/libManasMojoRuntime.a",
            sha256Digest: digest(12)
        )
        let bundle = try RuntimeWorkerAcceptanceContract.Artifact.RuntimeBundle(
            manifestDigest: digest(13),
            receiptDigest: digest(14),
            executable: executable,
            libraries: [library],
            loaderSearchPath: "lib",
            systemDependencies: ["libSystem.B.dylib"],
            programInterpreter: nil
        )
        return try .init(
            schemaVersion: 1,
            bundleDigest: digest(0),
            executionContractDigest: digest(1),
            semanticIdentity: semantic,
            generatedInputs: generated,
            runtimeBundle: bundle,
            targetClosure: target
        )
    }

    static func protocolRecord() throws
        -> RuntimeWorkerAcceptanceContract.ProtocolRecord
    {
        let kinds: [(UInt16, String)] = [
            (1, "ready"),
            (2, "createSession"),
            (3, "sessionCreated"),
            (4, "invokeFloat32"),
            (5, "invocationResult"),
            (6, "shutdownSession"),
            (7, "sessionShutdown"),
            (8, "shutdownWorker"),
            (9, "workerShutdown"),
            (10, "failure"),
        ]
        return try RuntimeWorkerAcceptanceContract.ProtocolRecord(
            version: 1,
            descriptor: 3,
            headerByteCount: 32,
            byteOrder: "little-endian",
            maximumFramePayloadBytes: 65_536,
            maximumInFlightRequests: 1,
            messageKinds: try kinds.map {
                try RuntimeWorkerAcceptanceContract.ProtocolRecord.MessageKind(
                    rawValue: $0.0,
                    name: $0.1
                )
            }
        )
    }

    static func base(
        status: RuntimeWorkerAcceptanceContract.Status,
        claims: RuntimeWorkerAcceptanceContract.Claims,
        host: RuntimeWorkerAcceptanceContract.Host,
        failure: RuntimeWorkerAcceptanceContract.Failure?,
        lifecycle: RuntimeWorkerAcceptanceContract.Lifecycle? = nil
    ) throws -> RuntimeWorkerAcceptanceContract {
        try .init(
            status: status,
            claims: claims,
            swiftMojoRevision: revision,
            acceptanceSourceDigest: digest(0),
            host: host,
            artifact: try artifact(),
            protocolRecord: try protocolRecord(),
            consumerBoundary: .init(
                publicRuntimeProjectionUsed: true,
                publicWorkerAPIUsed: true,
                filesystemAccessOutsideWorker: false,
                processLaunchOutsideWorker: false,
                runtimeLoaderOutsideWorker: false,
                rawPOSIXImports: false,
                rawProtocolImports: false,
                workerSPIImports: false
            ),
            executionEnvironment: try .init(
                compilerAvailableDuringExecution: false,
                pythonAvailableDuringExecution: false,
                ambientLoaderVariableNames: [],
                cleanEnvironmentObserved: true
            ),
            lifecycle: lifecycle ?? (try complete),
            failure: failure
        )
    }

    static func passed() throws -> RuntimeWorkerAcceptanceContract {
        try base(
            status: .passed,
            claims: .init(actualHostProcess: true, protocolLifecycle: true),
            host: try host(allObserved: true),
            failure: nil
        )
    }

    static func failed() throws -> RuntimeWorkerAcceptanceContract {
        try base(
            status: .failed,
            claims: .init(actualHostProcess: true, protocolLifecycle: false),
            host: try .init(
                platform: .macOS,
                architecture: "arm64",
                targetTriple: targetTriple,
                cpu: targetCPU,
                nativeTargetObserved: true,
                processLaunchObserved: true,
                protocolExchangeObserved: false
            ),
            failure: try .init(
                code: .protocolObservationMissing,
                message: "protocol exchange did not complete"
            ),
            lifecycle: try .init(
                stagingVerificationObserved: true,
                readyAdmissionObserved: true,
                sessionCreationObserved: false,
                nonEmptyInvocationInputElementCount: 0,
                nonEmptyInvocationOutputElementCount: 0,
                gracefulShutdownObserved: false,
                forcedFailureObserved: false,
                forcedFailureTimedOut: false,
                forcedFailureProcessGroupReaped: false,
                forcedFailurePartialOutputElementCount: 0,
                forcedFailureCleanupFailureCount: 0,
                cleanNextAttemptObserved: false
            )
        )
    }

    static var complete: RuntimeWorkerAcceptanceContract.Lifecycle {
        get throws {
            try .init(
                stagingVerificationObserved: true,
                readyAdmissionObserved: true,
                sessionCreationObserved: true,
                nonEmptyInvocationInputElementCount: 1,
                nonEmptyInvocationOutputElementCount: 1,
                gracefulShutdownObserved: true,
                forcedFailureObserved: true,
                forcedFailureTimedOut: true,
                forcedFailureProcessGroupReaped: true,
                forcedFailurePartialOutputElementCount: 0,
                forcedFailureCleanupFailureCount: 0,
                cleanNextAttemptObserved: true
            )
        }
    }
}

private func mutation(
    _ text: String,
    replacing needle: String,
    with replacement: String,
    sourceLocation: SourceLocation = #_sourceLocation
) -> Data {
    let occurrences = text.components(separatedBy: needle).count - 1
    #expect(
        occurrences == 1,
        "Expected one mutation site for '\(needle)', found \(occurrences)",
        sourceLocation: sourceLocation
    )
    return Data(text.replacingOccurrences(of: needle, with: replacement).utf8)
}

private func expectContractFailure(
    _ data: Data,
    context: String = "",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let contextSuffix = context.isEmpty ? "" : " (\(context))"
    #expect(
        throws: RuntimeWorkerAcceptanceError.self,
        "Expected contract failure\(contextSuffix)",
        sourceLocation: sourceLocation
    ) {
        try RuntimeWorkerAcceptanceContract.decodeCanonical(data)
    }
}

private func expectContractFailureContaining(
    _ data: Data,
    _ expectedDetail: String,
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        _ = try RuntimeWorkerAcceptanceContract.decodeCanonical(data)
        Issue.record(
            "Expected contract failure (\(context))",
            sourceLocation: sourceLocation
        )
    } catch let error as RuntimeWorkerAcceptanceError {
        #expect(
            error.description.contains(expectedDetail),
            "Unexpected failure for \(context): \(error)",
            sourceLocation: sourceLocation
        )
    } catch {
        Issue.record(
            "Unexpected error for \(context): \(error)",
            sourceLocation: sourceLocation
        )
    }
}
