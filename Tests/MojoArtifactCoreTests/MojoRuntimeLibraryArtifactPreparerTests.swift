import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

@Suite("Generated Mojo runtime library preparation")
struct MojoRuntimeLibraryArtifactPreparerTests {
    @Test(.timeLimit(.minutes(1)))
    func compilesTheExactInputGraphBeforeAtomicBundleCommit() throws {
        try withFixture { fixture in
            let manifest = try fixture.preparer.prepare(
                options: fixture.options,
                runtimeLibraryURLs: [fixture.runtimeLibraryURL]
            )
            let expectedGraph = try fixture.options.inputGraph()
            let rendered = MojoStaticSourceRenderer().render(
                inputGraph: expectedGraph,
                identity: fixture.identity
            )

            #expect(manifest.compilerVersion == FixtureCompiler.version)
            #expect(manifest.inputGraphDigest == expectedGraph.digest)
            #expect(
                manifest.inputGraphIdentifier
                    == expectedGraph.digestIdentifier
            )
            #expect(
                manifest.generatedSourceDigest
                    == MojoCanonicalDigest.hex(Data(rendered.source.utf8))
            )
            #expect(
                manifest.sourceMapDigest
                    == MojoCanonicalDigest.hex(
                        try rendered.sourceMap.encode()
                    )
            )
            #expect(
                try MojoRuntimeLibraryBundleVerifier().verify(
                    bundleURL: fixture.bundleURL
                ) == manifest
            )

            let invocation = try FoundationMojoProcessRunner(
                environment: [:],
                timeoutSeconds: 30
            ).capture(
                executablePath: fixture.runnerURL.path,
                arguments: [
                    fixture.bundleURL.appendingPathComponent(
                        manifest.library.relativePath
                    ).path,
                    String(fixture.bindingID),
                    "\(fixture.identity.symbolPrefix)_call_i32_i32_i32",
                ]
            )
            #expect(invocation.status == 0)
            #expect(invocation.output == "42\n")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceChangeBeforeCommitFailsWithoutPublishingABundle() throws {
        try withFixture(mutateSourceDuringCompilation: true) { fixture in
            #expect(throws: MojoBindingError.self) {
                _ = try fixture.preparer.prepare(
                    options: fixture.options,
                    runtimeLibraryURLs: [fixture.runtimeLibraryURL]
                )
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.bundleURL.path
                )
            )
        }
    }

    private func withFixture(
        mutateSourceDuringCompilation: Bool = false,
        operation: (Fixture) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-mojo-generated-runtime-library-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        do {
            let fixture = try Fixture(
                root: root,
                mutateSourceDuringCompilation: mutateSourceDuringCompilation
            )
            try operation(fixture)
            try FileManager.default.removeItem(at: root)
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch let cleanupError {
                throw MojoArtifactError.commandFailed(
                    command: "clean generated runtime library fixture",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
    }
}

private struct Fixture {
    let identity: MojoArtifactIdentity
    let bindingID: UInt64
    let runtimeLibraryURL: URL
    let bundleURL: URL
    let runnerURL: URL
    let options: MojoPrepareOptions
    let preparer: MojoRuntimeLibraryArtifactPreparer

    init(root: URL, mutateSourceDuringCompilation: Bool) throws {
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        try """
        import Mojo

        @mojo
        func add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
            return lhs + rhs
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        identity = try MojoArtifactIdentity(targetName: "GeneratedRuntime")
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic",
            accelerator: "metal:4"
        )
        bundleURL = root.appendingPathComponent(
            "GeneratedRuntime.bundle",
            isDirectory: true
        )
        options = try MojoPrepareOptions(
            sourceURLs: [sourceURL],
            sourceRootURL: root,
            outputDirectoryURL: bundleURL,
            identity: identity,
            targets: [target],
            expectedCompilerVersion: FixtureCompiler.version
        )
        let graph = try options.inputGraph()
        bindingID = try #require(graph.bindingGraph.bindings.first).bindingID
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(
            at: input,
            withIntermediateDirectories: false
        )
        let objectURL = input.appendingPathComponent("Bindings.o")
        runtimeLibraryURL = input.appendingPathComponent(
            "libFixtureRuntime.dylib"
        )
        try Self.compileInputs(
            inputDirectory: input,
            objectURL: objectURL,
            runtimeLibraryURL: runtimeLibraryURL,
            target: target,
            identity: identity,
            bindingID: bindingID,
            inputGraphIdentifier: graph.digestIdentifier
        )
        runnerURL = try Self.compileRunner(in: root)

        let runner = FoundationMojoProcessRunner(timeoutSeconds: 30)
        let inspector = MojoRuntimeBinaryInspector(processRunner: runner)
        let receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: inspector,
            processRunner: runner
        )
        let verifier = MojoRuntimeLibraryBundleVerifier(
            binaryInspector: inspector,
            processRunner: runner
        )
        preparer = MojoRuntimeLibraryArtifactPreparer(
            compiler: FixtureCompiler(
                objectURL: objectURL,
                sourceURLToMutate: mutateSourceDuringCompilation
                    ? sourceURL
                    : nil
            ),
            receiptPreparer: receiptPreparer,
            bundleBuilder: MojoRuntimeLibraryBundleBuilder(
                linker: MojoRuntimeLibraryLinker(processRunner: runner),
                receiptVerifier: MojoRuntimeReceiptVerifier(
                    preparer: receiptPreparer
                ),
                bundleVerifier: verifier
            ),
            bundleVerifier: verifier
        )
    }

    private static func compileInputs(
        inputDirectory: URL,
        objectURL: URL,
        runtimeLibraryURL: URL,
        target: MojoTargetConfiguration,
        identity: MojoArtifactIdentity,
        bindingID: UInt64,
        inputGraphIdentifier: UInt64
    ) throws {
        let runtimeSourceURL = inputDirectory.appendingPathComponent(
            "runtime.c"
        )
        try """
        int AsyncRT_fixture_runtime(int value) {
            return value + 1;
        }
        """.write(
            to: runtimeSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try runClang([
            "-target", target.triple,
            "-dynamiclib", runtimeSourceURL.path,
            "-Wl,-install_name,@rpath/\(runtimeLibraryURL.lastPathComponent)",
            "-o", runtimeLibraryURL.path,
        ])

        let prefix = identity.symbolPrefix
        let bindingSourceURL = inputDirectory.appendingPathComponent(
            "binding.c"
        )
        try """
        #include <stdint.h>

        extern int AsyncRT_fixture_runtime(int value);

        uint32_t \(prefix)_static_abi_version(void) { return 1; }
        uint64_t \(prefix)_input_graph_identifier(void) {
            return \(inputGraphIdentifier)ULL;
        }
        uint32_t \(prefix)_has_binding(uint64_t value) {
            return value == \(bindingID)ULL;
        }
        int32_t \(prefix)_call_i32_i32_i32(
            uint64_t value,
            int32_t lhs,
            int32_t rhs
        ) {
            if (value != \(bindingID)ULL) { return -1; }
            return AsyncRT_fixture_runtime(lhs + rhs);
        }
        """.write(
            to: bindingSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try runClang([
            "-target", target.triple,
            "-c", bindingSourceURL.path,
            "-o", objectURL.path,
        ])
    }

    private static func compileRunner(in root: URL) throws -> URL {
        let sourceURL = root.appendingPathComponent("runner.c")
        let runnerURL = root.appendingPathComponent("runner")
        try """
        #include <dlfcn.h>
        #include <stdint.h>
        #include <stdio.h>
        #include <stdlib.h>

        typedef int32_t (*call_i32)(uint64_t, int32_t, int32_t);

        int main(int argc, char **argv) {
            if (argc != 4) { return 10; }
            void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
            if (library == NULL) { return 11; }
            call_i32 call = (call_i32)dlsym(library, argv[3]);
            if (call == NULL) {
                dlclose(library);
                return 12;
            }
            uint64_t binding = strtoull(argv[2], NULL, 10);
            int32_t value = call(binding, 20, 21);
            if (dlclose(library) != 0) { return 13; }
            printf("%d\\n", value);
            return value == 42 ? 0 : 14;
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        try runClang([
            "-target", "arm64-apple-macosx14.0",
            sourceURL.path,
            "-o", runnerURL.path,
        ])
        return runnerURL
    }

    private static func runClang(_ arguments: [String]) throws {
        let result = try FoundationMojoProcessRunner(timeoutSeconds: 30)
            .capture(
                executablePath: "/usr/bin/xcrun",
                arguments: ["clang"] + arguments
            )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: (["xcrun", "clang"] + arguments).joined(
                    separator: " "
                ),
                status: result.status,
                diagnostic: result.output
            )
        }
    }
}

private struct FixtureCompiler: MojoObjectCompiling, Sendable {
    static let version = "Fixture Mojo 1.0"

    let objectURL: URL
    let sourceURLToMutate: URL?

    func compilerVersion() throws -> String {
        Self.version
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        let source = try String(
            contentsOfFile: inputPath,
            encoding: .utf8
        )
        guard source.contains("@export(\"") else {
            throw MojoArtifactError.invalidArguments(
                "fixture did not receive generated exports"
            )
        }
        try FileManager.default.copyItem(
            at: objectURL,
            to: URL(fileURLWithPath: outputPath)
        )
        if let sourceURLToMutate {
            let original = try String(
                contentsOf: sourceURLToMutate,
                encoding: .utf8
            )
            let changed = original.replacingOccurrences(
                of: "lhs + rhs",
                with: "lhs - rhs"
            )
            guard changed != original else {
                throw MojoArtifactError.invalidArguments(
                    "fixture source mutation did not change the binding"
                )
            }
            try changed.write(
                to: sourceURLToMutate,
                atomically: true,
                encoding: .utf8
            )
        }
        return ""
    }
}
