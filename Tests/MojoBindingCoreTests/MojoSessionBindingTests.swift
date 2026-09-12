import Foundation
import MojoBindingCore
import Testing

@Suite("Mojo session binding model")
struct MojoSessionBindingTests {
    @Test(.timeLimit(.minutes(1)))
    func opaqueResourceFactoriesAreResolvedBeforeGeneration() throws {
        let source = """
        @mojo(package: "Resource", function: "open", shutdown: "close")
        func open(_ requirements: MojoSessionRequirements) throws -> MojoSessionOwner
        @mojo(package: "Resource", function: "create", shutdown: "destroy", synchronize: "sync", sessionFactory: "open")
        func create(_ session: MojoSessionOwner, _ config: borrowing Span<UInt8>) throws -> MojoSessionResourceOwner
        @mojo(package: "Resource", function: "run", synchronize: "sync", sessionFactory: "open", resourceFactory: "create")
        func run(_ session: MojoSessionOwner, _ resources: borrowing Span<MojoSessionResourceOwner>) throws
        """
        let graph = try parse(source)
        #expect(graph.bindings.contains { $0.signature == .opaqueResourceFactory })
        #expect(graph.bindings.contains { $0.signature == .opaqueResourceOperation })
        #expect(throws: MojoBindingError.sessionFactoryNotFound("missing")) {
            try parse(source.replacingOccurrences(of: "resourceFactory: \"create\"", with: "resourceFactory: \"missing\""))
        }
        #expect(throws: MojoBindingError.unsupportedSignature) {
            try parse(source.replacingOccurrences(of: "borrowing Span<MojoSessionResourceOwner>", with: "[MojoSessionResourceOwner]"))
        }
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            try parse(source.replacingOccurrences(of: "synchronize: \"sync\", ", with: ""))
        }
        let changed = try parse(source.replacingOccurrences(of: "synchronize: \"sync\"", with: "synchronize: \"drain\""))
        #expect(changed.digest != graph.digest)
    }

    @Test(.timeLimit(.minutes(1)))
    func acceptanceDeclarationsUseTheCurrentDirectGrammar() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
        ), encoding: .utf8)
        let bindings = try parse(source).bindings
        #expect(bindings.count == 3)
        #expect(bindings.filter { $0.signature == .runtimeSessionFactory }.count == 1)
        #expect(bindings.filter { $0.signature == .sessionBorrowedMutableFloat32Buffers }.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func factoryAndBoundCallProduceLinkedSessionMetadata() throws {
        let graph = try parse(
            """
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
                _ input: borrowing Span<Float>,
                into output: inout MutableSpan<Float>
            ) throws
            """
        )

        #expect(graph.bindings.count == 2)
        let factory = try #require(
            graph.bindings.first { $0.signature == .runtimeSessionFactory }
        )
        let mutation = try #require(
            graph.bindings.first {
                $0.signature == .sessionBorrowedMutableFloat32Buffers
            }
        )
        #expect(
            factory.implementation == .session(
                package: "SessionModel",
                create: "create_session",
                shutdown: "shutdown_session"
            )
        )
        #expect(
            mutation.implementation == .sessionExternal(
                package: "SessionModel",
                function: "scale",
                sessionFactory: "openSession"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func bufferFactoryProducesLinkedSessionResourceMetadata() throws {
        let graph = try parse(
            """
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
            """
        )

        let resource = try #require(
            graph.bindings.first {
                $0.signature == .sessionFloat32BufferFactory
            }
        )
        #expect(
            resource.implementation == .sessionResource(
                package: "SessionModel",
                create: "create_buffer",
                shutdown: "destroy_buffer",
                copyFromHost: "copy_from_host",
                copyToHost: "copy_to_host",
                synchronize: "synchronize",
                sessionFactory: "openSession"
            )
        )
        #expect(resource.parameterNames == [
            "session",
            "elementCount",
            "memoryKind",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func boundCallRejectsMissingFactory() {
        #expect(
            throws: MojoBindingError.sessionFactoryNotFound("openSession")
        ) {
            _ = try parse(
                """
                @mojo(
                    package: "SessionModel",
                    function: "scale",
                    sessionFactory: "openSession"
                )
                func scale(
                    _ session: MojoSessionOwner,
                    _ input: borrowing Span<Float>,
                    into output: inout MutableSpan<Float>
                ) throws
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func boundCallRejectsFactoryFromDifferentPackage() {
        #expect(
            throws: MojoBindingError.sessionPackageMismatch(
                binding: "OtherModel",
                factory: "SessionModel"
            )
        ) {
            _ = try parse(
                """
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
                    _ input: borrowing Span<Float>,
                    into output: inout MutableSpan<Float>
                ) throws
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bufferFactoryRejectsMissingSessionFactory() {
        #expect(
            throws: MojoBindingError.sessionFactoryNotFound("openSession")
        ) {
            _ = try parse(
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
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionMetadataMustBeCompleteStringLiterals() {
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            _ = try parse(
                """
                @mojo(package: "SessionModel", function: "create_session")
                func openSession(
                    _ requirements: MojoSessionRequirements
                ) throws -> MojoSessionOwner
                """
            )
        }
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            _ = try parse(
                """
                @mojo(package: "SessionModel", function: factory, shutdown: "shutdown_session")
                func openSession(
                    _ requirements: MojoSessionRequirements
                ) throws -> MojoSessionOwner
                """
            )
        }
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            _ = try parse(
                """
                @mojo(package: "SessionModel", function: "scale")
                func scale(
                    _ session: MojoSessionOwner,
                    _ input: borrowing Span<Float>,
                    into output: inout MutableSpan<Float>
                ) throws
                """
            )
        }
        #expect(throws: MojoBindingError.invalidSessionArguments) {
            _ = try parse(
                """
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
                    function: "create_buffer",
                    shutdown: "destroy_buffer",
                    copyFromHost: "copy_from_host",
                    sessionFactory: "openSession"
                )
                func makeBuffer(
                    _ session: MojoSessionOwner,
                    elementCount: UInt64,
                    memoryKind: MojoBufferMemoryKind
                ) throws -> MojoFloat32BufferOwner
                """
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func bufferFactoryRejectsInvalidTransferFunctionName() {
        #expect(
            throws: MojoBindingError.unsupportedExternalFunctionName(
                "invalid-transfer!"
            )
        ) {
            _ = try parse(
                """
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
                    function: "create_buffer",
                    shutdown: "destroy_buffer",
                    copyFromHost: "invalid-transfer!",
                    copyToHost: "copy_to_host",
                    synchronize: "synchronize",
                    sessionFactory: "openSession"
                )
                func makeBuffer(
                    _ session: MojoSessionOwner,
                    elementCount: UInt64,
                    memoryKind: MojoBufferMemoryKind
                ) throws -> MojoFloat32BufferOwner
                """
            )
        }
    }

    private func parse(_ source: String) throws -> MojoSourceGraph {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove session binding fixture: \(error)")
            }
        }
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        return try MojoSourceGraph(sourceURLs: [sourceURL])
    }
}
