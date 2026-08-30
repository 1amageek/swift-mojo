import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MojoMacros

final class MojoStaticArtifactAttestationMacroTests: XCTestCase {
    func testExpansionUsesTargetLocalGeneratedRegistry() {
        assertMacroExpansion(
            """
            @mojoStaticArtifactAttestation
            public func trainingArtifactAttestation()
                throws -> MojoStaticArtifactAttestation
            """,
            expandedSource: """
            public func trainingArtifactAttestation()
                throws -> MojoStaticArtifactAttestation {
                return try __SwiftMojoGeneratedBindings.staticArtifactAttestation()
            }
            """,
            macros: [
                "mojoStaticArtifactAttestation":
                    MojoStaticArtifactAttestationMacro.self,
            ],
            indentationWidth: .spaces(4)
        )
    }

    func testParametersAreRejected() {
        assertMacroExpansion(
            """
            @mojoStaticArtifactAttestation
            func invalid(_ value: Int)
                throws -> MojoStaticArtifactAttestation
            """,
            expandedSource: """
            func invalid(_ value: Int)
                throws -> MojoStaticArtifactAttestation
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@mojoStaticArtifactAttestation requires a bodyless synchronous parameterless throwing function returning MojoStaticArtifactAttestation",
                    line: 1,
                    column: 1
                ),
            ],
            macros: [
                "mojoStaticArtifactAttestation":
                    MojoStaticArtifactAttestationMacro.self,
            ],
            indentationWidth: .spaces(4)
        )
    }

    func testCallerBodyIsRejected() {
        assertMacroExpansion(
            """
            @mojoStaticArtifactAttestation
            func invalid() throws -> MojoStaticArtifactAttestation {
                fatalError("self-reported attestation")
            }
            """,
            expandedSource: """
            func invalid() throws -> MojoStaticArtifactAttestation {
                fatalError("self-reported attestation")
            }
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@mojoStaticArtifactAttestation requires a bodyless synchronous parameterless throwing function returning MojoStaticArtifactAttestation",
                    line: 1,
                    column: 1
                ),
            ],
            macros: [
                "mojoStaticArtifactAttestation":
                    MojoStaticArtifactAttestationMacro.self,
            ],
            indentationWidth: .spaces(4)
        )
    }
}
