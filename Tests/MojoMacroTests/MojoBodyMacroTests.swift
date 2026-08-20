import SwiftSyntaxMacrosTestSupport
import XCTest
@testable import MojoMacros

final class MojoBodyMacroTests: XCTestCase {
    func testInlineBindingExpansion() {
        assertMacroExpansion(
            """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                mojo {
                    return a + b
                }
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

    func testArgumentsAreRejected() {
        assertMacroExpansion(
            """
            @mojo(symbol: "swift_mojo_add", library: "MojoBindings")
            func add(_ a: Int32, _ b: Int32) throws -> Int32
            """,
            expandedSource: """
            func add(_ a: Int32, _ b: Int32) throws -> Int32
            """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@mojo does not accept arguments; write Mojo code in the function's mojo block",
                    line: 1,
                    column: 1
                ),
            ],
            macros: ["mojo": MojoBodyMacro.self],
            indentationWidth: .spaces(4)
        )
    }
}
