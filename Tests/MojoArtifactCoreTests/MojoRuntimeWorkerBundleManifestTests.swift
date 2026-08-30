import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore
import Testing

@Suite("Mojo runtime worker bundle manifest")
struct MojoRuntimeWorkerBundleManifestTests {
    @Test(.timeLimit(.minutes(1)))
    func deterministicRoundTripPreservesManifestDigest() throws {
        let fixture = try Fixture()
        let manifest = try fixture.manifest()
        let encoded = try manifest.encoded()
        let decoded = try MojoRuntimeWorkerBundleManifest.decode(encoded)

        #expect(decoded == manifest)
        #expect(try decoded.encoded() == encoded)
        #expect(decoded.digest == manifest.digest)
        #expect(manifest.digest.count == 64)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNestedUnknownAndMissingKeys() throws {
        let fixture = try Fixture()
        let encoded = try fixture.manifest().encoded()
        let source = try #require(String(data: encoded, encoding: .utf8))
        let unknown = try replacingExactlyOnce(
            in: source,
            fragment: "\"compilerVersion\" : \"fixture-compiler\",",
            with: "\"compilerVersion\" : \"fixture-compiler\",\n      \"unknownGeneratedInput\" : true,"
        )
        let missing = try replacingExactlyOnce(
            in: source,
            fragment:
                "\"sourceGraphIdentifier\" : \(fixture.sourceGraphIdentifier),",
            with: ""
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.decode(Data(unknown.utf8))
        }
        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.decode(Data(missing.utf8))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNonCanonicalBindingTables() throws {
        let fixture = try Fixture()

        #expect(throws: MojoArtifactError.self) {
            try fixture.semanticIdentity(bindings: fixture.bindings.reversed())
        }
        #expect(throws: MojoArtifactError.self) {
            try fixture.semanticIdentity(bindings: [
                fixture.bindings[0],
                .init(
                    bindingID: fixture.bindings[0].bindingID,
                    functionName: "duplicateBinding",
                    signature: .borrowedFloat32Buffer,
                    sessionFactoryFunctionName: nil
                ),
            ])
        }
        #expect(throws: MojoArtifactError.self) {
            try fixture.semanticIdentity(bindings: [
                fixture.bindings[0],
                .init(
                    bindingID: fixture.bindings[1].bindingID ^ 1,
                    functionName: fixture.bindings[1].functionName,
                    signature: fixture.bindings[1].signature,
                    sessionFactoryFunctionName: fixture.bindings[1]
                        .sessionFactoryFunctionName
                ),
            ])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNonCanonicalProtocolKindTables() throws {
        let canonical = MojoRuntimeProtocol.kindTable.map(
            MojoRuntimeWorkerBundleManifest.MessageKind.init
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.ProtocolRecord(
                version: MojoRuntimeProtocol.version,
                descriptor:
                    MojoRuntimeWorkerBundleManifest.ProtocolRecord.descriptor,
                headerByteCount: MojoRuntimeProtocol.headerByteCount,
                byteOrder:
                    MojoRuntimeWorkerBundleManifest.ProtocolRecord.byteOrder,
                maximumFramePayloadBytes: 4_096,
                maximumInFlightRequests:
                    MojoRuntimeProtocol.maximumInFlightRequests,
                messageKinds: canonical.reversed()
            )
        }
        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.ProtocolRecord(
                version: MojoRuntimeProtocol.version,
                descriptor:
                    MojoRuntimeWorkerBundleManifest.ProtocolRecord.descriptor,
                headerByteCount: MojoRuntimeProtocol.headerByteCount,
                byteOrder:
                    MojoRuntimeWorkerBundleManifest.ProtocolRecord.byteOrder,
                maximumFramePayloadBytes: 4_096,
                maximumInFlightRequests:
                    MojoRuntimeProtocol.maximumInFlightRequests,
                messageKinds: Array(canonical.dropLast()) + [canonical[0]]
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsDigestAndTargetClosureDrift() throws {
        let fixture = try Fixture()
        let manifest = try fixture.manifest()
        let encoded = try #require(
            String(data: manifest.encoded(), encoding: .utf8)
        )
        let invalidHex = try replacingExactlyOnce(
            in: encoded,
            fragment: String(repeating: "1", count: 64),
            with: String(repeating: "G", count: 64)
        )
        let semanticDrift = try replacingExactlyOnce(
            in: encoded,
            fragment:
                "\"sourceGraphIdentifier\" : \(fixture.sourceGraphIdentifier)",
            with:
                "\"sourceGraphIdentifier\" : \(fixture.sourceGraphIdentifier ^ 1)"
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.decode(Data(invalidHex.utf8))
        }
        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeWorkerBundleManifest.decode(Data(semanticDrift.utf8))
        }
    }
}

private struct Fixture {
    let target: MojoTargetConfiguration
    let identity: MojoArtifactIdentity
    let sourceGraphDigest: String
    let sourceGraphIdentifier: UInt64
    let inputGraphDigest: String
    let inputGraphIdentifier: UInt64
    let bindings: [MojoRuntimeWorkerBundleManifest.Binding]

    init() throws {
        self.target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m2-max",
            accelerator: "metal"
        )
        self.identity = try MojoArtifactIdentity(targetName: "WorkerFixture")
        let sourceGraphDigest = String(repeating: "1", count: 64)
        self.sourceGraphDigest = sourceGraphDigest
        self.sourceGraphIdentifier = try #require(
            MojoCanonicalDigest.identifier(
                fromSHA256Hex: sourceGraphDigest
            )
        )
        let inputGraphDigest = String(repeating: "2", count: 64)
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = try #require(
            MojoCanonicalDigest.identifier(
                fromSHA256Hex: inputGraphDigest
            )
        )
        self.bindings = [
            .init(
                bindingID: MojoBinding.bindingIdentifier(
                    functionName: "createSession",
                    signature: .runtimeSessionFactory
                ),
                functionName: "createSession",
                signature: .runtimeSessionFactory,
                sessionFactoryFunctionName: nil
            ),
            .init(
                bindingID: MojoBinding.bindingIdentifier(
                    functionName: "invoke",
                    signature: .sessionBorrowedMutableFloat32Buffers
                ),
                functionName: "invoke",
                signature: .sessionBorrowedMutableFloat32Buffers,
                sessionFactoryFunctionName: "createSession"
            ),
        ]
    }

    func semanticIdentity<S: Sequence>(
        bindings: S
    ) throws -> MojoRuntimeWorkerBundleManifest.SemanticIdentity
    where S.Element == MojoRuntimeWorkerBundleManifest.Binding {
        try MojoRuntimeWorkerBundleManifest.SemanticIdentity(
            workerABIVersion: MojoRuntimeWorkerRenderer.workerABIVersion,
            protocolVersion: MojoRuntimeProtocol.version,
            sourceGraphDigest: sourceGraphDigest,
            sourceGraphIdentifier: sourceGraphIdentifier,
            inputGraphDigest: inputGraphDigest,
            inputGraphIdentifier: inputGraphIdentifier,
            generationPipelineDigest: String(repeating: "3", count: 64),
            bindings: Array(bindings)
        )
    }

    func manifest() throws -> MojoRuntimeWorkerBundleManifest {
        let semanticIdentity = try semanticIdentity(bindings: bindings)
        let generatedInputs = try MojoRuntimeWorkerBundleManifest.GeneratedInputs(
            generatedMojoSourceDigest: String(repeating: "4", count: 64),
            generatedCWorkerSourceDigest: String(repeating: "5", count: 64),
            sourceMapDigest: String(repeating: "6", count: 64),
            generatedMojoObjectDigest: String(repeating: "7", count: 64),
            generatedCWorkerObjectDigest: String(repeating: "8", count: 64),
            compilerVersion: "fixture-compiler"
        )
        let runtimeBundle = try MojoRuntimeWorkerBundleManifest.RuntimeBundleRecord(
            manifestDigest: String(repeating: "9", count: 64),
            receiptDigest: String(repeating: "a", count: 64),
            executable: .init(
                relativePath: "bin/worker",
                digest: String(repeating: "b", count: 64)
            ),
            libraries: [
                try .init(
                    relativePath: "lib/libAsyncRT.dylib",
                    digest: String(repeating: "c", count: 64)
                ),
            ],
            loaderSearchPath: "@executable_path/../lib",
            systemDependencies: ["/usr/lib/libSystem.B.dylib"],
            programInterpreter: nil
        )
        let executionContractDigest = String(repeating: "d", count: 64)
        let targetClosureDigest = try MojoRuntimeWorkerBundleManifest
            .targetClosureDigest(
                semanticIdentity: semanticIdentity,
                generatedInputs: generatedInputs,
                runtimeBundle: runtimeBundle,
                target: target,
                artifactIdentity: identity,
                executionContractDigest: executionContractDigest
            )
        let targetClosure = try MojoRuntimeWorkerBundleManifest.TargetClosure(
            target: target,
            artifactIdentity: identity,
            targetClosureDigest: targetClosureDigest
        )
        return try MojoRuntimeWorkerBundleManifest(
            semanticIdentity: semanticIdentity,
            generatedInputs: generatedInputs,
            protocolRecord: .init(maximumFramePayloadBytes: 4_096),
            runtimeBundle: runtimeBundle,
            targetClosure: targetClosure,
            executionContractDigest: executionContractDigest
        )
    }
}

private func replacingExactlyOnce(
    in source: String,
    fragment: String,
    with replacement: String
) throws -> String {
    let occurrences = source.components(separatedBy: fragment).count - 1
    #expect(occurrences == 1)
    guard occurrences == 1 else {
        throw MojoArtifactError.invalidArguments(
            "test mutation fragment must occur exactly once"
        )
    }
    return source.replacingOccurrences(of: fragment, with: replacement)
}
