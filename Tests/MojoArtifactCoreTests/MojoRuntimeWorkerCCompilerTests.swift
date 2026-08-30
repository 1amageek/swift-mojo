import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

private struct RuntimeWorkerClangRunner: MojoProcessRunning {
    let expectedExecutablePath: String
    let expectedArguments: [String]
    let outputURL: URL?
    let result: MojoProcessResult

    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        #expect(executablePath == expectedExecutablePath)
        #expect(arguments == expectedArguments)
        if let outputURL {
            try Data("fixture object".utf8).write(to: outputURL)
        }
        return result
    }
}

private struct RejectingRuntimeWorkerClangRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        throw MojoArtifactError.invalidArguments(
            "Compiler process must not run for rejected inputs"
        )
    }
}

@Suite("Mojo runtime worker C compiler")
struct MojoRuntimeWorkerCCompilerTests {
    @Test(.timeLimit(.minutes(1)))
    func compilesAndLinksTwoObjectsWithHostClang() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let helperSourceURL = fixture.rootURL.appendingPathComponent(
                "Helper.c"
            )
            let helperObjectURL = fixture.outputDirectoryURL
                .appendingPathComponent("Helper.o")
            let executableURL = fixture.outputDirectoryURL
                .appendingPathComponent("worker")
            try Data("int helper(void) { return 42; }\n".utf8).write(
                to: helperSourceURL
            )
            let runner = FoundationMojoProcessRunner(timeoutSeconds: 30)
            let compiler = MojoRuntimeWorkerCCompiler(
                processRunner: runner,
                environment: [:]
            )
            try compiler.compile(
                sourceURL: fixture.sourceURL,
                includeDirectoryURL: fixture.includeDirectoryURL,
                outputURL: fixture.outputURL,
                target: fixture.target
            )
            try compiler.compile(
                sourceURL: helperSourceURL,
                includeDirectoryURL: fixture.includeDirectoryURL,
                outputURL: helperObjectURL,
                target: fixture.target
            )

            try MojoRuntimeExecutableLinker(
                processRunner: runner,
                environment: [:]
            ).link(
                objectURLs: [fixture.outputURL, helperObjectURL],
                libraryURLs: [],
                outputURL: executableURL,
                target: fixture.target,
                systemDependencies: []
            )

            try MojoRegularFile.validate(at: executableURL)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: executableURL.path
            )
            let permissions = try #require(
                attributes[.posixPermissions] as? NSNumber
            ).intValue
            #expect(permissions & 0o111 != 0)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func compilesAValidatedTargetSpecificCObject() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let arguments = [
                "-target", fixture.target.triple,
                "-mcpu=\(fixture.target.cpu)",
                "-std=c11",
                "-Werror",
                "-I", fixture.includeDirectoryURL.path,
                "-c", fixture.sourceURL.path,
                "-o", fixture.outputURL.path,
            ]
            let compiler = MojoRuntimeWorkerCCompiler(
                processRunner: RuntimeWorkerClangRunner(
                    expectedExecutablePath: "/toolchain/clang",
                    expectedArguments: arguments,
                    outputURL: fixture.outputURL,
                    result: MojoProcessResult(status: 0, output: "")
                ),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            try compiler.compile(
                sourceURL: fixture.sourceURL,
                includeDirectoryURL: fixture.includeDirectoryURL,
                outputURL: fixture.outputURL,
                target: fixture.target
            )

            try MojoRegularFile.validate(at: fixture.outputURL)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preservesCompilerFailureStatusAndDiagnostic() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let arguments = [
                "-target", fixture.target.triple,
                "-mcpu=\(fixture.target.cpu)",
                "-std=c11",
                "-Werror",
                "-I", fixture.includeDirectoryURL.path,
                "-c", fixture.sourceURL.path,
                "-o", fixture.outputURL.path,
            ]
            let compiler = MojoRuntimeWorkerCCompiler(
                processRunner: RuntimeWorkerClangRunner(
                    expectedExecutablePath: "/toolchain/clang",
                    expectedArguments: arguments,
                    outputURL: nil,
                    result: MojoProcessResult(
                        status: 7,
                        output: "invalid worker source\n"
                    )
                ),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            do {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
                Issue.record("Failed C compilation unexpectedly succeeded")
            } catch let error as MojoArtifactError {
                guard case .commandFailed(
                    _,
                    let status,
                    let diagnostic
                ) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(status == 7)
                #expect(diagnostic == "invalid worker source")
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingInputsAndOutputDirectoryBeforeLaunch() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let compiler = rejectingCompiler()
            let missingSource = fixture.rootURL.appendingPathComponent(
                "Missing.c"
            )
            let missingHeaders = fixture.rootURL.appendingPathComponent(
                "MissingHeaders",
                isDirectory: true
            )
            let missingOutput = fixture.rootURL
                .appendingPathComponent("MissingOutput", isDirectory: true)
                .appendingPathComponent("Worker.o")

            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: missingSource,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
            }
            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: missingHeaders,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
            }
            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: missingOutput,
                    target: fixture.target
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsSymbolicLinkInputsAndOutputDirectoryBeforeLaunch() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let sourceLink = fixture.rootURL.appendingPathComponent(
                "WorkerLink.c"
            )
            let includeLink = fixture.rootURL.appendingPathComponent(
                "HeaderLink",
                isDirectory: true
            )
            let outputLink = fixture.rootURL.appendingPathComponent(
                "OutputLink",
                isDirectory: true
            )
            try FileManager.default.createSymbolicLink(
                at: sourceLink,
                withDestinationURL: fixture.sourceURL
            )
            try FileManager.default.createSymbolicLink(
                at: includeLink,
                withDestinationURL: fixture.includeDirectoryURL
            )
            try FileManager.default.createSymbolicLink(
                at: outputLink,
                withDestinationURL: fixture.outputDirectoryURL
            )
            let compiler = rejectingCompiler()

            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: sourceLink,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
            }
            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: includeLink,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
            }
            #expect(throws: MojoArtifactError.self) {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: outputLink.appendingPathComponent("Worker.o"),
                    target: fixture.target
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnsupportedTargetBeforeLaunch() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let unsupported = try MojoTargetConfiguration(
                triple: "wasm32-unknown-wasi",
                cpu: "generic"
            )

            #expect(throws: MojoArtifactError.self) {
                try rejectingCompiler().compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: fixture.outputURL,
                    target: unsupported
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsSuccessfulCommandWithoutAnObject() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let arguments = [
                "-target", fixture.target.triple,
                "-mcpu=\(fixture.target.cpu)",
                "-std=c11",
                "-Werror",
                "-I", fixture.includeDirectoryURL.path,
                "-c", fixture.sourceURL.path,
                "-o", fixture.outputURL.path,
            ]
            let compiler = MojoRuntimeWorkerCCompiler(
                processRunner: RuntimeWorkerClangRunner(
                    expectedExecutablePath: "/toolchain/clang",
                    expectedArguments: arguments,
                    outputURL: nil,
                    result: MojoProcessResult(status: 0, output: "")
                ),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            #expect(throws: MojoCompilerToolError.self) {
                try compiler.compile(
                    sourceURL: fixture.sourceURL,
                    includeDirectoryURL: fixture.includeDirectoryURL,
                    outputURL: fixture.outputURL,
                    target: fixture.target
                )
            }
        }
    }
}

@Suite("Mojo runtime executable multi-object linker")
struct MojoRuntimeExecutableLinkerTests {
    @Test(.timeLimit(.minutes(1)))
    func linksEveryGeneratedObjectWithTheAppleLoaderContract() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let secondObjectURL = fixture.outputDirectoryURL
                .appendingPathComponent("Dispatch.o")
            try Data("second object".utf8).write(to: secondObjectURL)
            let libraryURL = fixture.rootURL.appendingPathComponent(
                "libRuntime.dylib"
            )
            try Data("runtime library".utf8).write(to: libraryURL)
            let executableURL = fixture.outputDirectoryURL
                .appendingPathComponent("worker")
            let arguments = [
                "-target", fixture.target.triple,
                fixture.sourceURL.path,
                secondObjectURL.path,
                libraryURL.path,
                "-Wl,-rpath,@executable_path/../lib",
                "-o", executableURL.path,
            ]
            let linker = MojoRuntimeExecutableLinker(
                processRunner: RuntimeWorkerClangRunner(
                    expectedExecutablePath: "/toolchain/clang",
                    expectedArguments: arguments,
                    outputURL: nil,
                    result: MojoProcessResult(status: 0, output: "")
                ),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            try linker.link(
                objectURLs: [fixture.sourceURL, secondObjectURL],
                libraryURLs: [libraryURL],
                outputURL: executableURL,
                target: fixture.target,
                systemDependencies: ["/usr/lib/libSystem.B.dylib"]
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preservesLinuxOriginAndExplicitSystemDependencies() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let target = try MojoTargetConfiguration(
                triple: "aarch64-unknown-linux-gnu",
                cpu: "cortex-a78ae",
                accelerator: "nvidia-gpu"
            )
            let libraryURL = fixture.rootURL.appendingPathComponent(
                "libRuntime.so"
            )
            try Data("runtime library".utf8).write(to: libraryURL)
            let executableURL = fixture.outputDirectoryURL
                .appendingPathComponent("worker")
            let arguments = [
                "-target", target.triple,
                fixture.sourceURL.path,
                libraryURL.path,
                "-Wl,-l:libcustom.so.1",
                "-Wl,-rpath,$ORIGIN/../lib",
                "-Wl,--enable-new-dtags",
                "-o", executableURL.path,
            ]
            let linker = MojoRuntimeExecutableLinker(
                processRunner: RuntimeWorkerClangRunner(
                    expectedExecutablePath: "/toolchain/clang",
                    expectedArguments: arguments,
                    outputURL: nil,
                    result: MojoProcessResult(status: 0, output: "")
                ),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            try linker.link(
                objectURLs: [fixture.sourceURL],
                libraryURLs: [libraryURL],
                outputURL: executableURL,
                target: target,
                systemDependencies: ["libm.so.6", "libcustom.so.1"]
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsInvalidObjectSetsBeforeLaunch() throws {
        try withRuntimeWorkerCompilerFixture { fixture in
            let linker = MojoRuntimeExecutableLinker(
                processRunner: RejectingRuntimeWorkerClangRunner(),
                environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
            )

            #expect(throws: MojoArtifactError.self) {
                try linker.link(
                    objectURLs: [],
                    libraryURLs: [],
                    outputURL: fixture.outputURL,
                    target: fixture.target,
                    systemDependencies: []
                )
            }
            #expect(throws: MojoArtifactError.self) {
                try linker.link(
                    objectURLs: [fixture.sourceURL, fixture.sourceURL],
                    libraryURLs: [],
                    outputURL: fixture.outputURL,
                    target: fixture.target,
                    systemDependencies: []
                )
            }

            let sourceLink = fixture.rootURL.appendingPathComponent(
                "ObjectLink.o"
            )
            try FileManager.default.createSymbolicLink(
                at: sourceLink,
                withDestinationURL: fixture.sourceURL
            )
            #expect(throws: MojoArtifactError.self) {
                try linker.link(
                    objectURLs: [sourceLink],
                    libraryURLs: [],
                    outputURL: fixture.outputURL,
                    target: fixture.target,
                    systemDependencies: []
                )
            }
            #expect(throws: (any Error).self) {
                try linker.link(
                    objectURLs: [
                        fixture.rootURL.appendingPathComponent("Missing.o"),
                    ],
                    libraryURLs: [],
                    outputURL: fixture.outputURL,
                    target: fixture.target,
                    systemDependencies: []
                )
            }
        }
    }
}

private struct RuntimeWorkerCompilerFixture {
    let rootURL: URL
    let sourceURL: URL
    let includeDirectoryURL: URL
    let outputDirectoryURL: URL
    let outputURL: URL
    let target: MojoTargetConfiguration
}

private func rejectingCompiler() -> MojoRuntimeWorkerCCompiler {
    MojoRuntimeWorkerCCompiler(
        processRunner: RejectingRuntimeWorkerClangRunner(),
        environment: ["SWIFT_MOJO_CLANG": "/toolchain/clang"]
    )
}

private func withRuntimeWorkerCompilerFixture(
    _ operation: (RuntimeWorkerCompilerFixture) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-mojo-worker-compiler-tests-\(UUID().uuidString)",
        isDirectory: true
    )
    let includeDirectory = root.appendingPathComponent(
        "include",
        isDirectory: true
    )
    let outputDirectory = root.appendingPathComponent(
        "objects",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: false
    )
    do {
        try FileManager.default.createDirectory(
            at: includeDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        let source = root.appendingPathComponent("Worker.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        try Data("#pragma once\n".utf8).write(
            to: includeDirectory.appendingPathComponent("Bindings.h")
        )
        let fixture = RuntimeWorkerCompilerFixture(
            rootURL: root,
            sourceURL: source,
            includeDirectoryURL: includeDirectory,
            outputDirectoryURL: outputDirectory,
            outputURL: outputDirectory.appendingPathComponent("Worker.o"),
            target: try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "apple-m4",
                accelerator: "apple-gpu"
            )
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
                command: "clean runtime worker compiler fixture",
                status: -1,
                diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
            )
        }
        throw primaryError
    }
}
