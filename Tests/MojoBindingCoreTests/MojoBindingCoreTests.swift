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
                return a + b
            }
            """
        )
        let reformatted = try graph(
            source: """
            @mojo()
            func add(_ a: Int32, _ b: Int32) -> Int32 { return a+b }
            """
        )

        #expect(first.digest == reformatted.digest)
        #expect(first.digestIdentifier == reformatted.digestIdentifier)
        #expect(first.bindings.count == 1)
        #expect(first.bindings[0].bindingID == 788870723690667806)
        #expect(first.bindings[0].functionName == "add")
        #expect(first.bindings[0].implementation == .inline(.addForward))
    }

    @Test(.timeLimit(.minutes(1)))
    func implementationChangeInvalidatesSourceGraph() throws {
        let forward = try graph(
            source: """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                return a + b
            }
            """
        )
        let reversed = try graph(
            source: """
            @mojo
            func add(_ a: Int32, _ b: Int32) -> Int32 {
                return b + a
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
                    return a - b
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
    func externalBindingProducesCanonicalImplementationIdentity() throws {
        let external = try graph(
            source: """
            @mojo(package: "MathModel", function: "add")
            func add(_ a: Int32, _ b: Int32) -> Int32
            """
        )

        #expect(
            external.bindings[0].implementation
                == .external(package: "MathModel", function: "add")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func externalBorrowedFloatBufferProducesTypedSignature() throws {
        let external = try graph(
            source: """
            @mojo(package: "MathModel", function: "sum")
            func sum(_ values: [Float]) throws -> Float
            """
        )

        #expect(external.bindings[0].signature == .borrowedFloat32Buffer)
        #expect(external.bindings[0].parameterNames == ["values"])
        #expect(
            external.bindings[0].implementation
                == .external(package: "MathModel", function: "sum")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func externalMutableFloatBufferProducesTypedSignature() throws {
        let external = try graph(
            source: """
            @mojo(package: "MathModel", function: "scale")
            func scale(
                _ input: [Float],
                into output: inout [Float]
            ) throws
            """
        )

        #expect(
            external.bindings[0].signature
                == .borrowedMutableFloat32Buffers
        )
        #expect(external.bindings[0].parameterNames == ["input", "output"])
        #expect(
            external.bindings[0].implementation
                == .external(package: "MathModel", function: "scale")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func mutableFloatBufferRequiresInoutAndThrowingSurface() throws {
        #expect(throws: MojoBindingError.unsupportedSignature) {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "scale")
                func scale(_ input: [Float], into output: [Float]) throws
                """
            )
        }
        #expect(throws: MojoBindingError.unsupportedSignature) {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "scale")
                func scale(_ input: [Float], into output: inout [Float])
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func scalarAndBufferOverloadsHaveDistinctABIIdentities() throws {
        let overloads = try graph(
            source: """
            @mojo(package: "MathModel", function: "add")
            func reduce(_ lhs: Int32, _ rhs: Int32) -> Int32

            @mojo(package: "MathModel", function: "sum")
            func reduce(_ values: [Float]) throws -> Float
            """
        )

        #expect(overloads.bindings.count == 2)
        #expect(Set(overloads.bindings.map(\.bindingID)).count == 2)
        #expect(
            Set(overloads.bindings.map(\.signature))
                == [.int32Binary, .borrowedFloat32Buffer]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func borrowedFloatBufferRequiresExternalImplementation() throws {
        do {
            _ = try graph(
                source: """
                @mojo
                func sum(_ values: [Float]) throws -> Float {
                    return values.reduce(0, +)
                }
                """
            )
            Issue.record("Inline borrowed buffer unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(error == .bufferRequiresExternalImplementation)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mutableFloatBufferRequiresExternalImplementation() throws {
        #expect(throws: MojoBindingError.bufferRequiresExternalImplementation) {
            _ = try graph(
                source: """
                @mojo
                func scale(
                    _ input: [Float],
                    into output: inout [Float]
                ) throws {
                    output = input
                }
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionFactoryAndUseProduceLinkedTypedBindings() throws {
        let graph = try graph(
            source: """
            @mojo(
                package: "SessionModel",
                function: "create_session",
                shutdown: "shutdown_session"
            )
            func openSession(
                _ requirements: MojoSessionRequirements
            ) throws -> MojoSessionOwner

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
            """
        )

        let factory = try #require(
            graph.bindings.first { $0.signature == .runtimeSessionFactory }
        )
        let use = try #require(
            graph.bindings.first {
                $0.signature == .sessionBorrowedMutableFloat32Buffers
            }
        )
        #expect(factory.parameterNames == ["requirements"])
        #expect(
            factory.implementation == .session(
                package: "SessionModel",
                create: "create_session",
                shutdown: "shutdown_session"
            )
        )
        #expect(use.parameterNames == ["session", "input", "output"])
        #expect(
            use.implementation == .sessionExternal(
                package: "SessionModel",
                function: "scale",
                sessionFactory: "openSession"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionFactoryRequiresPairedShutdownMetadata() throws {
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            _ = try graph(
                source: """
                @mojo(package: "SessionModel", function: "create_session")
                func openSession(
                    _ requirements: MojoSessionRequirements
                ) throws -> MojoSessionOwner
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionUseRequiresExistingFactoryInSamePackage() throws {
        #expect(
            throws: MojoBindingError.sessionFactoryNotFound("openSession")
        ) {
            _ = try graph(
                source: """
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
                """
            )
        }

        #expect(
            throws: MojoBindingError.sessionPackageMismatch(
                binding: "OtherModel",
                factory: "SessionModel"
            )
        ) {
            _ = try graph(
                source: """
                @mojo(
                    package: "SessionModel",
                    function: "create_session",
                    shutdown: "shutdown_session"
                )
                func openSession(
                    _ requirements: MojoSessionRequirements
                ) throws -> MojoSessionOwner

                @mojo(
                    package: "OtherModel",
                    function: "scale",
                    sessionFactory: "openSession"
                )
                func scale(
                    _ session: MojoSessionOwner,
                    _ input: [Float],
                    into output: inout [Float]
                ) throws
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func borrowedFloatBufferRequiresTypedFailureSurface() throws {
        #expect(throws: MojoBindingError.unsupportedSignature) {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "sum")
                func sum(_ values: [Float]) -> Float
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func borrowedFloatBufferRejectsTypedThrows() throws {
        #expect(throws: MojoBindingError.unsupportedSignature) {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "sum")
                func sum(_ values: [Float]) throws(BufferError) -> Float
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func externalBindingRejectsReservedMojoIdentifiers() throws {
        do {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "return")
                func add(_ a: Int32, _ b: Int32) -> Int32
                """
            )
            Issue.record("Reserved Mojo identifier unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(
                error == .unsupportedExternalFunctionName("return")
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func externalBindingRejectsKeywordOperatorIdentifiers() throws {
        do {
            _ = try graph(
                source: """
                @mojo(package: "MathModel", function: "and")
                func add(_ a: Int32, _ b: Int32) -> Int32
                """
            )
            Issue.record("Mojo keyword unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(
                error == .unsupportedExternalFunctionName("and")
            )
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
                    return a + b
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
                    return a + b
                    #else
                    return b + a
                    #endif
                }
                """
            )
            Issue.record("Conditional binding body unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(error == .conditionalCompilationUnsupported)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func memberBindingIsRejectedUntilIdentityIncludesTypeContext() throws {
        do {
            _ = try graph(
                source: """
                struct Math {
                    @mojo
                    func add(_ a: Int32, _ b: Int32) -> Int32 {
                        return a + b
                    }
                }
                """
            )
            Issue.record("Member binding unexpectedly succeeded")
        } catch let error as MojoBindingError {
            #expect(error == .nonFileScopeUnsupported)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func malformedSwiftSourceIsRejectedBeforeBindingExtraction() throws {
        do {
            _ = try graph(
                source: """
                @mojo
                func add(_ a: Int32, _ b: Int32) -> Int32 {
                    return a + b
                """
            )
            Issue.record("Malformed Swift source unexpectedly succeeded")
        } catch let error as MojoBindingError {
            guard case .invalidSwiftSyntax(
                file: "Bindings.swift",
                diagnosticCount: let count
            ) = error else {
                Issue.record("Unexpected binding error: \(error)")
                return
            }
            #expect(count > 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func symbolicLinkSwiftSourceIsRejected() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let source = root.appendingPathComponent("Actual.swift")
        let link = root.appendingPathComponent("Bindings.swift")
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return a + b
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove symbolic source fixture: \(error)")
            }
        }

        #expect(throws: MojoBindingError.invalidSourceFile(link.path)) {
            _ = try MojoSourceGraph(sourceURLs: [link])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func symbolicPackageRootKeepsCanonicalRelativeSourceIdentity() throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let actualRoot = container.appendingPathComponent(
            "ActualPackage",
            isDirectory: true
        )
        let linkedRoot = container.appendingPathComponent(
            "LinkedPackage",
            isDirectory: true
        )
        let relativeSourcePath = "Implementation/API/Bindings.swift"
        let actualSource = actualRoot.appendingPathComponent(relativeSourcePath)
        try fileManager.createDirectory(
            at: actualSource.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return a + b
        }
        """.write(to: actualSource, atomically: true, encoding: .utf8)
        try fileManager.createSymbolicLink(
            at: linkedRoot,
            withDestinationURL: actualRoot
        )
        defer {
            do {
                try fileManager.removeItem(at: container)
            } catch {
                Issue.record("Failed to remove linked package fixture: \(error)")
            }
        }

        let graph = try MojoSourceGraph(
            sourceURLs: [linkedRoot.appendingPathComponent(relativeSourcePath)],
            sourceRootURL: linkedRoot
        )

        #expect(graph.bindings[0].sourceReference?.file == relativeSourcePath)
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
