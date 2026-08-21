import Foundation
import MojoBindingCore
import Testing

@Suite("Mojo session binding model")
struct MojoSessionBindingTests {
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
                _ input: [Float],
                into output: inout [Float]
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
                    _ input: [Float],
                    into output: inout [Float]
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
                    _ input: [Float],
                    into output: inout [Float]
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
                    _ input: [Float],
                    into output: inout [Float]
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
