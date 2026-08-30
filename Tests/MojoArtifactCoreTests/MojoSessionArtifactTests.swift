import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Mojo runtime session artifact")
struct MojoSessionArtifactTests {
    @Test(.timeLimit(.minutes(1)))
    func preparesVersionedOwnedSessionABI() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bindings.swift")
        let package = root.appendingPathComponent(
            "Mojo/SessionModel",
            isDirectory: true
        )
        let output = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove session artifact fixture: \(error)")
            }
        }
        try "# Fixture source is hashed but not compiled by the fixture compiler.\n"
            .write(
                to: package.appendingPathComponent("__init__.mojo"),
                atomically: true,
                encoding: .utf8
            )
        try """
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
        """.write(to: source, atomically: true, encoding: .utf8)
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx15.0",
            cpu: "generic"
        )
        let identity = try MojoArtifactIdentity(targetName: "SessionModel")
        let externalPackage = try MojoExternalPackage(
            name: "SessionModel",
            rootURL: package
        )
        let options = try MojoPrepareOptions(
            sourceURLs: [source],
            sourceRootURL: root,
            externalPackages: [externalPackage],
            outputDirectoryURL: output,
            identity: identity,
            targets: [target]
        )
        let result = try MojoArtifactPreparer(
            compiler: SessionFixtureMojoCompiler(),
            processRunner: FixturePackagingRunner()
        ).prepare(options: options)
        let generatedMojo = try String(
            contentsOf: output.appendingPathComponent("Bindings.mojo"),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: output
                .appendingPathComponent(identity.artifactName)
                .appendingPathComponent("fixture-slice-0")
                .appendingPathComponent("\(identity.moduleName).framework")
                .appendingPathComponent("Headers")
                .appendingPathComponent("\(identity.moduleName).h"),
            encoding: .utf8
        )
        let registryURL = root.appendingPathComponent("Registry.swift")
        _ = try MojoArtifactVerifier().verify(
            options: MojoVerifyOptions(
                sourceURLs: [source],
                sourceRootURL: root,
                externalPackages: [externalPackage],
                outputDirectoryURL: output,
                generatedSourceURL: registryURL,
                target: target,
                expectedIdentity: identity
            )
        )
        let registry = try String(contentsOf: registryURL, encoding: .utf8)
        let inputGraph = try options.inputGraph()

        #expect(generatedMojo.contains("OpaquePointer[MutUntrackedOrigin]"))
        #expect(generatedMojo.contains("_create_session_v1"))
        #expect(generatedMojo.contains("_shutdown_session_v1"))
        #expect(generatedMojo.contains("_create_f32_buffer_v1"))
        #expect(generatedMojo.contains("_shutdown_f32_buffer_v1"))
        #expect(generatedMojo.contains("_copy_host_to_f32_buffer_v1"))
        #expect(generatedMojo.contains("_copy_f32_buffer_to_host_v1"))
        #expect(generatedMojo.contains("__swift_mojo_resource_copy_from_host"))
        #expect(generatedMojo.contains("__swift_mojo_resource_copy_to_host"))
        #expect(generatedMojo.contains("__swift_mojo_resource_synchronize"))
        #expect(generatedMojo.contains("if status != 0"))
        #expect(generatedMojo.contains("element_count: UInt64"))
        #expect(generatedMojo.contains("memory_kind: UInt32"))
        #expect(
            generatedMojo.contains(
                "_call_session_f32_buffer_f32_buffer_i32_v1"
            )
        )
        #expect(header.contains("void **session_out"))
        #expect(header.contains("void *session"))
        #expect(header.contains("uint64_t element_count"))
        #expect(header.contains("uint32_t memory_kind"))
        #expect(header.contains("void **buffer_out"))
        #expect(header.contains("const float *source"))
        #expect(header.contains("float *destination"))
        #expect(registry.contains("@_spi(SwiftMojoGenerated) import Mojo"))
        #expect(registry.contains("static func makeSession"))
        #expect(registry.contains("static func staticArtifactAttestation"))
        #expect(registry.contains("MojoStaticArtifactPreflight"))
        #expect(registry.contains("preparedAttestationBindings"))
        #expect(registry.contains(identity.targetName))
        #expect(registry.contains(identity.moduleName))
        #expect(registry.contains(inputGraph.bindingGraph.digest))
        #expect(registry.contains(inputGraph.digest))
        #expect(registry.contains(target.triple))
        #expect(registry.contains(target.cpu))
        let validationRange = try #require(
            registry.range(of: "try artifactPreflight.requireValid()")
        )
        let sessionCreationRange = try #require(
            registry.range(of: "_create_session_v1(")
        )
        #expect(validationRange.lowerBound < sessionCreationRange.lowerBound)
        #expect(!registry.contains("dlopen"))
        #expect(!registry.contains("dlsym"))
        #expect(registry.contains("static func makeFloat32Buffer"))
        #expect(registry.contains("MojoFloat32BufferOwner.create"))
        #expect(registry.contains("memoryKind.rawValue"))
        #expect(registry.contains("copyFromHost:"))
        #expect(registry.contains("copyToHost:"))
        #expect(
            registry.contains("resourceCreationReturnedNoHandle")
        )
        #expect(registry.contains("if let handle"))
        #expect(registry.contains("_shutdown_session_v1(bindingID, handle)"))
        #expect(registry.contains("static func invokeSessionFloatBufferMutation"))
        #expect(registry.contains("session.withOpaqueHandle"))
        #expect(registry.contains("expectedSessionDomainID"))
        #expect(
            result.manifest.generationPipelineDigest
                == MojoGenerationPipeline.digest(for: inputGraph)
        )
        #expect(
            result.manifest.generationPipelineDigest
                != MojoGenerationPipeline.digest
        )
    }
}

private struct SessionFixtureMojoCompiler: MojoObjectCompiling {
    func compilerVersion() throws -> String {
        "fixture-mojo 1.0"
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        guard importSearchPaths.count == 1,
              URL(fileURLWithPath: importSearchPaths[0]).lastPathComponent
                == ".imports",
              try FileManager.default.contentsOfDirectory(
                atPath: importSearchPaths[0]
              ) == ["SessionModel"] else {
            throw MojoArtifactError.invalidArguments(
                "Session fixture requires an isolated SessionModel import root"
            )
        }
        try Data("fixture object \(target.identity)".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        return ""
    }
}
