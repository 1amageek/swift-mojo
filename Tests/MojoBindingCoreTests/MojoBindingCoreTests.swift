import Foundation
import MojoBindingCore
import Testing

@Suite("Inline Mojo binding model")
struct MojoBindingCoreTests {
    @Test(.timeLimit(.minutes(1)))
    func exactSyntaxProducesStableCanonicalIdentity() throws {
        let first = try graph(
            source: """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                mojo {
                    return a + b
                }
            }
            """
        )
        let reformatted = try graph(
            source: """
            @mojo()
            func add(_ a: Int32, _ b: Int32) -> Int32 { mojo { return a+b } }
            """
        )

        #expect(first.digest == reformatted.digest)
        #expect(first.digestIdentifier == reformatted.digestIdentifier)
        #expect(first.bindings.count == 1)
        #expect(first.bindings[0].functionName == "add")
        #expect(first.bindings[0].operation == .addForward)
    }

    @Test(.timeLimit(.minutes(1)))
    func implementationChangeInvalidatesSourceGraph() throws {
        let forward = try graph(
            source: """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                mojo { return a + b }
            }
            """
        )
        let reversed = try graph(
            source: """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                mojo { return b + a }
            }
            """
        )

        #expect(forward.bindings[0].bindingID == reversed.bindings[0].bindingID)
        #expect(
            forward.bindings[0].implementationDigest
                != reversed.bindings[0].implementationDigest
        )
        #expect(forward.digest != reversed.digest)
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedExpressionFailsExplicitly() throws {
        do {
            _ = try graph(
                source: """
                @mojo
                func subtract(_ a: Int32, _ b: Int32) -> Int32 {
                    mojo { return a - b }
                }
                """
            )
            Issue.record("Unsupported expression unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(
                error == .unsupportedExpression("a - b")
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func externalBindingIsNotPartOfInlineSourceGraph() throws {
        do {
            _ = try graph(
                source: """
                @mojo(symbol: "swift_mojo_add")
                func add(_ a: Int32, _ b: Int32) throws -> Int32
                """
            )
            Issue.record("External binding unexpectedly entered inline graph")
        } catch let error as MojoBindingError {
            #expect(error == .noBindings)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func conditionalCompilationIsRejectedExplicitly() throws {
        do {
            _ = try graph(
                source: """
                #if DEBUG
                @mojo
                func add(_ a: Int32, _ b: Int32) -> Int32 {
                    mojo { return a + b }
                }
                #endif
                """
            )
            Issue.record("Conditionally compiled binding unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(error == .conditionalCompilationUnsupported)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func conditionalCompilationInsideBindingIsRejectedExplicitly() throws {
        do {
            _ = try graph(
                source: """
                @mojo
                func add(_ a: Int32, _ b: Int32) -> Int32 {
                    #if DEBUG
                    mojo { return a + b }
                    #else
                    mojo { return b + a }
                    #endif
                }
                """
            )
            Issue.record("Conditional binding body unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(error == .conditionalCompilationUnsupported)
        }
    }

    private func graph(source: String) throws -> MojoSourceGraph {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        do {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            let graph = try MojoSourceGraph(sourceURLs: [sourceURL])
            try FileManager.default.removeItem(at: root)
            return graph
        } catch {
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch let cleanupError {
                Issue.record("Temporary fixture cleanup failed: \(cleanupError)")
            }
            throw error
        }
    }
}
