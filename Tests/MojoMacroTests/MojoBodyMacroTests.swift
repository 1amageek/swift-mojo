import MojoBindingCore
import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MojoMacros

final class MojoBodyMacroTests: XCTestCase {
    func testInlineBindingExpansion() {
        assertMacroExpansion(
            """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                return a + b
            }
            """,
            expandedSource: """
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                guard !a.addingReportingOverflow(b).overflow else {
                    fatalError("Inline @mojo Int32 addition overflowed")
                }
                return __SwiftMojoGeneratedBindings.invokeInt32Binary(
                    bindingID: UInt64(788870723690667806),
                    lhs: a,
                    rhs: b
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testExternalBindingExpansionDoesNotAssumeAdditionSemantics() {
        assertMacroExpansion(
            """
            @mojo(package: "MathModel", function: "add")
            func add(_ a: Int32, _ b: Int32) -> Int32
            """,
            expandedSource: """
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                return __SwiftMojoGeneratedBindings.invokeInt32Binary(
                    bindingID: UInt64(788870723690667806),
                    lhs: a,
                    rhs: b
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testBorrowedFloatBufferExpansionUsesThrowingScopedRegistry() {
        let bindingID = MojoCanonicalDigest.identifier(
            "swift-mojo-binding-v1|sum|([Float])->throws Float"
        )
        assertMacroExpansion(
            """
            @mojo(package: "MathModel", function: "sum")
            func sum(_ values: [Float]) throws -> Float
            """,
            expandedSource: """
            func sum(_ values: [Float]) throws -> Float {
                return try __SwiftMojoGeneratedBindings.invokeFloatBuffer(
                    bindingID: UInt64(\(bindingID)),
                    values: values
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testMutableFloatBufferExpansionUsesScopedRegistry() {
        let bindingID = MojoCanonicalDigest.identifier(
            "swift-mojo-binding-v1|scale|([Float],inout [Float])->throws Void"
        )
        assertMacroExpansion(
            """
            @mojo(package: "MathModel", function: "scale")
            func scale(
                _ input: [Float],
                into output: inout [Float]
            ) throws
            """,
            expandedSource: """
            func scale(
                _ input: [Float],
                into output: inout [Float]
            ) throws {
                try __SwiftMojoGeneratedBindings.invokeFloatBufferMutation(
                    bindingID: UInt64(\(bindingID)),
                    input: input,
                    output: &output
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testSessionFactoryExpansionUsesTypedRegistryFactory() {
        let bindingID = MojoCanonicalDigest.identifier(
            "swift-mojo-binding-v1|openSession|(MojoSessionRequirements)->throws MojoSessionOwner"
        )
        assertMacroExpansion(
            """
            @mojo(
                package: "SessionModel",
                function: "create_session",
                shutdown: "shutdown_session"
            )
            func openSession(
                _ requirements: MojoSessionRequirements
            ) throws -> MojoSessionOwner
            """,
            expandedSource: """
            func openSession(
                _ requirements: MojoSessionRequirements
            ) throws -> MojoSessionOwner {
                return try __SwiftMojoGeneratedBindings.makeSession(
                    bindingID: UInt64(\(bindingID)),
                    requirements: requirements
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testSessionBufferFactoryExpansionUsesTypedRegistryFactory() {
        let bindingID = MojoCanonicalDigest.identifier(
            "swift-mojo-binding-v1|makeBuffer|(MojoSessionOwner,UInt64,MojoBufferMemoryKind)->throws MojoFloat32BufferOwner"
        )
        assertMacroExpansion(
            """
            @mojo(
                package: "SessionModel",
                function: "create_buffer",
                shutdown: "destroy_buffer",
                copyFromHost: "copy_from_host",
                copyToHost: "copy_to_host",
                synchronize: "synchronize",
                sessionFactory: "openSession"
            )
            func makeBuffer(
                _ session: MojoSessionOwner,
                elementCount: UInt64,
                memoryKind: MojoBufferMemoryKind
            ) throws -> MojoFloat32BufferOwner
            """,
            expandedSource: """
            func makeBuffer(
                _ session: MojoSessionOwner,
                elementCount: UInt64,
                memoryKind: MojoBufferMemoryKind
            ) throws -> MojoFloat32BufferOwner {
                return try __SwiftMojoGeneratedBindings.makeFloat32Buffer(
                    bindingID: UInt64(\(bindingID)),
                    session: session,
                    elementCount: elementCount,
                    memoryKind: memoryKind
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

    func testSessionMutationExpansionBorrowsOwnerAndBuffers() {
        let bindingID = MojoCanonicalDigest.identifier(
            "swift-mojo-binding-v1|scale|(MojoSessionOwner,[Float],inout [Float])->throws Void"
        )
        assertMacroExpansion(
            """
            @mojo(
                package: "SessionModel",
                function: "scale",
                sessionFactory: "openSession"
            )
            func scale(
                _ session: MojoSessionOwner,
                _ input: [Float],
                into output: inout [Float]
            ) throws
            """,
            expandedSource: """
            func scale(
                _ session: MojoSessionOwner,
                _ input: [Float],
                into output: inout [Float]
            ) throws {
                try __SwiftMojoGeneratedBindings.invokeSessionFloatBufferMutation(
                    bindingID: UInt64(\(bindingID)),
                    session: session,
                    input: input,
                    output: &output
                )
            }
            """,
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }

}
