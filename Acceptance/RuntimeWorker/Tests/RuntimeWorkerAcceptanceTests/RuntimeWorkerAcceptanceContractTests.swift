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
        let withUnknownKey = Data(
            text.replacingOccurrences(
                of: "\"compilerVersion\":\"mojo 1.0\"",
                with: "\"compilerVersion\":\"mojo 1.0\",\"unknown\":true"
            ).utf8
        )
        let withoutNestedKey = Data(
            text.replacingOccurrences(
                of: "\"compilerVersion\":\"mojo 1.0\",",
                with: ""
            ).utf8
        )

        expectContractFailure(withUnknownKey)
        expectContractFailure(withoutNestedKey)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNonCanonicalWhitespaceAndDuplicateKeys() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let text = String(decoding: encoded, as: UTF8.self)
        let withWhitespace = Data((text + "\n").utf8)
        let withDuplicateKey = Data(
            (text.dropLast() + ",\"status\":\"passed\"}").utf8
        )

        expectContractFailure(withWhitespace)
        expectContractFailure(withDuplicateKey)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsPassWithoutActualHostObservation() throws {
        let encoded = try ReceiptFixture.passed().encoded()
        let mutation = Data(
            String(decoding: encoded, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"nativeTargetObserved\":true",
                    with: "\"nativeTargetObserved\":false"
                )
                .utf8
        )

        expectContractFailure(mutation)
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
        try .init(
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
        try .init(
            version: 1,
            descriptor: 3,
            headerByteCount: 32,
            byteOrder: "little-endian",
            maximumFramePayloadBytes: 65_536,
            maximumInFlightRequests: 1,
            messageKinds: RuntimeWorkerAcceptanceContract.ProtocolRecord
                .expectedMessageKinds
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

private func expectContractFailure(_ data: Data, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(
        throws: RuntimeWorkerAcceptanceError.self,
        sourceLocation: sourceLocation
    ) {
        try RuntimeWorkerAcceptanceContract.decodeCanonical(data)
    }
}
