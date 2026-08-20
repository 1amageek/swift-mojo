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
}
