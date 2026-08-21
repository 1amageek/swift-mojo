import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Mutable Mojo buffer artifact")
struct MojoMutableBufferArtifactTests {
    @Test(.timeLimit(.minutes(1)))
    func preparesScopedMutableBufferABIAndTypedRegistry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bindings.swift")
        let package = root.appendingPathComponent(
            "Mojo/MathModel",
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
                Issue.record("Failed to remove mutable buffer fixture: \(error)")
            }
        }
        try """
        from std.memory import Pointer

        def scale(
            input: Pointer[Float32, ImmUntrackedOrigin],
            input_count: UInt64,
            output: Pointer[Float32, MutUntrackedOrigin],
            output_count: UInt64,
        ) -> Int32:
            if output_count < input_count:
                return 7
            for index in range(Int(input_count)):
                output[unsafe_offset=index] = input[unsafe_offset=index] * 2
            return 0
        """.write(
            to: package.appendingPathComponent("__init__.mojo"),
            atomically: true,
            encoding: .utf8
        )
        try """
        @mojo(package: "MathModel", function: "scale")
        func scale(_ input: [Float], into output: inout [Float]) throws
        """.write(to: source, atomically: true, encoding: .utf8)
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )
        let identity = try MojoArtifactIdentity(targetName: "Math")
        let externalPackage = try MojoExternalPackage(
            name: "MathModel",
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
            compiler: FixtureMojoCompiler(),
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

        #expect(result.manifest.bindings.count == 1)
        #expect(generatedMojo.contains("Pointer[Float32, ImmUntrackedOrigin]"))
        #expect(generatedMojo.contains("Pointer[Float32, MutUntrackedOrigin]"))
        #expect(generatedMojo.contains("_call_f32_buffer_f32_buffer_i32"))
        #expect(generatedMojo.contains(") abi(\"C\") -> Int32:"))
        #expect(generatedMojo.contains("return -1"))
        #expect(
            header.contains(
                "int32_t \(identity.symbolPrefix)_call_f32_buffer_f32_buffer_i32("
            )
        )
        #expect(header.contains("const float *input"))
        #expect(header.contains("float *output"))
        #expect(registry.contains("input: borrowing [Float]"))
        #expect(registry.contains("output: inout [Float]"))
        #expect(registry.contains("input.withUnsafeBufferPointer"))
        #expect(registry.contains("output.withUnsafeMutableBufferPointer"))
        #expect(registry.contains("MojoInvocationError.emptyBorrowedBuffer"))
        #expect(registry.contains("MojoInvocationError.emptyMutableBuffer"))
        #expect(registry.contains("MojoInvocationError.invocationFailed"))
        #expect(registry.contains("guard status == 0"))
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
