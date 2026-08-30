@_spi(SwiftMojoGenerated) import Mojo
import CMojoStaticPreflightFixture
import Testing

@Suite("Mojo static artifact preflight")
struct MojoStaticArtifactPreflightTests {
    @Test(.timeLimit(.minutes(1)))
    func validPreflightReturnsExactAttestationAndRunsOperation() throws {
        let attestation = Self.attestation()
        let preflight = MojoStaticArtifactPreflight(
            expectedABIVersion: attestation.abiVersion,
            actualABIVersion: { attestation.abiVersion },
            expectedInputGraphIdentifier: attestation.inputGraphIdentifier,
            actualInputGraphIdentifier: {
                attestation.inputGraphIdentifier
            },
            bindingIDs: attestation.bindings.map(\.bindingID),
            hasBinding: { _ in true }
        )
        var invocationCount = 0

        #expect(try preflight.validatedAttestation(attestation) == attestation)
        let value = try preflight.withValidatedArtifact {
            invocationCount += 1
            return 42
        }

        #expect(value == 42)
        #expect(invocationCount == 1)
    }

    @Test(
        arguments: [
            MojoInvocationError.incompatibleStaticABI(
                expected: 1,
                actual: 2
            ),
            MojoInvocationError.inputGraphMismatch(
                expected: 101,
                actual: 202
            ),
            MojoInvocationError.bindingUnavailable(bindingID: 303),
        ]
    )
    func mismatchRejectsBeforeGuardedOperation(
        expectedError: MojoInvocationError
    ) {
        let preflight: MojoStaticArtifactPreflight
        switch expectedError {
        case .incompatibleStaticABI:
            preflight = MojoStaticArtifactPreflight(
                expectedABIVersion: 1,
                actualABIVersion: { 2 },
                expectedInputGraphIdentifier: 101,
                actualInputGraphIdentifier: { 101 },
                bindingIDs: [303],
                hasBinding: { _ in true }
            )
        case .inputGraphMismatch:
            preflight = MojoStaticArtifactPreflight(
                expectedABIVersion: 1,
                actualABIVersion: { 1 },
                expectedInputGraphIdentifier: 101,
                actualInputGraphIdentifier: { 202 },
                bindingIDs: [303],
                hasBinding: { _ in true }
            )
        case .bindingUnavailable:
            preflight = MojoStaticArtifactPreflight(
                expectedABIVersion: 1,
                actualABIVersion: { 1 },
                expectedInputGraphIdentifier: 101,
                actualInputGraphIdentifier: { 101 },
                bindingIDs: [303],
                hasBinding: { _ in false }
            )
        default:
            Issue.record("Unexpected preflight fixture error")
            return
        }
        var invocationCount = 0

        #expect(throws: expectedError) {
            try preflight.withValidatedArtifact {
                invocationCount += 1
            }
        }
        #expect(invocationCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func linkedStaticShimIsFailFastAndPreventsSessionCreation() throws {
        let bindingIDs: [UInt64] = [11, 22, 33]

        swift_mojo_preflight_fixture_reset(
            UInt32(SWIFT_MOJO_PREFLIGHT_ABI_MISMATCH),
            0
        )
        var preflight = Self.linkedPreflight(bindingIDs: bindingIDs)
        #expect(throws: MojoInvocationError.incompatibleStaticABI(
            expected: 1,
            actual: 2
        )) {
            try preflight.withValidatedArtifact {
                swift_mojo_preflight_fixture_create_session()
            }
        }
        #expect(swift_mojo_preflight_fixture_abi_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_graph_call_count() == 0)
        #expect(swift_mojo_preflight_fixture_binding_call_count() == 0)
        #expect(swift_mojo_preflight_fixture_session_call_count() == 0)

        swift_mojo_preflight_fixture_reset(
            UInt32(SWIFT_MOJO_PREFLIGHT_GRAPH_MISMATCH),
            0
        )
        preflight = Self.linkedPreflight(bindingIDs: bindingIDs)
        #expect(throws: MojoInvocationError.inputGraphMismatch(
            expected: 101,
            actual: 202
        )) {
            try preflight.withValidatedArtifact {
                swift_mojo_preflight_fixture_create_session()
            }
        }
        #expect(swift_mojo_preflight_fixture_abi_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_graph_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_binding_call_count() == 0)
        #expect(swift_mojo_preflight_fixture_session_call_count() == 0)

        for (missingIndex, missingBindingID) in bindingIDs.enumerated() {
            swift_mojo_preflight_fixture_reset(
                UInt32(SWIFT_MOJO_PREFLIGHT_BINDING_MISSING),
                missingBindingID
            )
            preflight = Self.linkedPreflight(bindingIDs: bindingIDs)
            #expect(throws: MojoInvocationError.bindingUnavailable(
                bindingID: missingBindingID
            )) {
                try preflight.withValidatedArtifact {
                    swift_mojo_preflight_fixture_create_session()
                }
            }
            #expect(swift_mojo_preflight_fixture_abi_call_count() == 1)
            #expect(swift_mojo_preflight_fixture_graph_call_count() == 1)
            #expect(
                swift_mojo_preflight_fixture_binding_call_count()
                    == UInt32(missingIndex + 1)
            )
            for index in 0...missingIndex {
                #expect(
                    swift_mojo_preflight_fixture_binding_call(UInt32(index))
                        == bindingIDs[index]
                )
            }
            #expect(swift_mojo_preflight_fixture_session_call_count() == 0)
        }

        swift_mojo_preflight_fixture_reset(
            UInt32(SWIFT_MOJO_PREFLIGHT_SUCCESS),
            0
        )
        preflight = Self.linkedPreflight(bindingIDs: bindingIDs)
        #expect(try preflight.withValidatedArtifact {
            swift_mojo_preflight_fixture_create_session()
        } == 0)
        #expect(swift_mojo_preflight_fixture_abi_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_graph_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_binding_call_count() == 3)
        #expect(swift_mojo_preflight_fixture_session_call_count() == 1)
        #expect(try preflight.withValidatedArtifact {
            swift_mojo_preflight_fixture_create_session()
        } == 0)
        #expect(swift_mojo_preflight_fixture_abi_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_graph_call_count() == 1)
        #expect(swift_mojo_preflight_fixture_binding_call_count() == 3)
        #expect(swift_mojo_preflight_fixture_session_call_count() == 2)
    }

    private static func linkedPreflight(
        bindingIDs: [UInt64]
    ) -> MojoStaticArtifactPreflight {
        MojoStaticArtifactPreflight(
            expectedABIVersion: 1,
            actualABIVersion: {
                swift_mojo_preflight_fixture_abi_version()
            },
            expectedInputGraphIdentifier: 101,
            actualInputGraphIdentifier: {
                swift_mojo_preflight_fixture_input_graph()
            },
            bindingIDs: bindingIDs,
            hasBinding: {
                swift_mojo_preflight_fixture_has_binding($0) == 1
            }
        )
    }

    private static func attestation() -> MojoStaticArtifactAttestation {
        MojoStaticArtifactAttestation(
            schemaVersion: 5,
            abiVersion: 1,
            compilerVersion: "Mojo 1.0",
            generationPipelineDigest: String(repeating: "a", count: 64),
            targetName: "Training",
            moduleName: "SwiftMojo_Training_ABI",
            sourceGraphDigest: String(repeating: "b", count: 64),
            sourceGraphIdentifier: 100,
            inputGraphDigest: String(repeating: "c", count: 64),
            inputGraphIdentifier: 101,
            generatedSourceDigest: String(repeating: "d", count: 64),
            sourceMapDigest: String(repeating: "e", count: 64),
            artifactSetDigest: String(repeating: "f", count: 64),
            nativeArtifactAdapter: .appleXCFramework,
            nativeArtifactName: "SwiftMojo_Training_ABI.xcframework",
            nativeArtifactDigest: String(repeating: "1", count: 64),
            targetTriple: "arm64-apple-macosx15.0",
            targetCPU: "apple-m4",
            targetAccelerator: "apple-gpu",
            libraryIdentifier: "macos-arm64",
            archiveDigest: String(repeating: "2", count: 64),
            bindings: [
                MojoStaticArtifactAttestation.Binding(
                    bindingID: 303,
                    functionName: "create_session",
                    abiDigest: String(repeating: "3", count: 64),
                    implementationDigest: String(repeating: "4", count: 64)
                ),
            ]
        )
    }
}
