import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore
import Synchronization
import Testing

@Suite("Mojo runtime worker artifact preparation", .serialized)
struct MojoRuntimeWorkerArtifactPreparerTests {
    @Test(.timeLimit(.minutes(1)))
    func rejectsInvalidPayloadLimitsBeforeCompilation() throws {
        try withWorkerPreparerFixture { fixture in
            for maximumFramePayloadBytes in [
                UInt64(0),
                MojoRuntimeProtocol.hardMaximumFramePayloadBytes + 1,
            ] {
                #expect(throws: MojoRuntimeProtocolError.invalidLimit) {
                    _ = try fixture.prepare(
                        maximumFramePayloadBytes: maximumFramePayloadBytes
                    )
                }
            }

            #expect(fixture.trace.compilerVersionCount == 0)
            #expect(fixture.trace.mojoCompilationCount == 0)
            #expect(fixture.trace.workerCompilationCount == 0)
            try fixture.verifyPublishedState()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingOrMultipleAcceleratorTargetsBeforeCompilation() throws {
        try withWorkerPreparerFixture { fixture in
            let noAccelerator = try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "generic"
            )
            let secondTarget = try MojoTargetConfiguration(
                triple: "aarch64-unknown-linux-gnu",
                cpu: "generic",
                accelerator: "nvidia-gpu"
            )

            #expect(
                throws: MojoArtifactError.invalidArguments(
                    "A runtime worker preparation requires an explicit accelerator target"
                )
            ) {
                _ = try fixture.prepare(targets: [noAccelerator])
            }
            #expect(
                throws: MojoArtifactError.invalidArguments(
                    "A runtime worker preparation requires exactly one target slice"
                )
            ) {
                _ = try fixture.prepare(
                    targets: [fixture.target, secondTarget]
                )
            }

            #expect(fixture.trace.compilerVersionCount == 0)
            #expect(fixture.trace.mojoCompilationCount == 0)
            #expect(fixture.trace.workerCompilationCount == 0)
            try fixture.verifyPublishedState()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsGeneratedHeaderDriftWithoutChangingPublishedOutput() throws {
        try withWorkerPreparerFixture(
            workerMutation: .generatedHeader
        ) { fixture in
            #expect(
                throws: MojoArtifactError.inputsChangedDuringOperation(
                    "runtime worker C compilation"
                )
            ) {
                _ = try fixture.prepare()
            }

            #expect(fixture.trace.compilerVersionCount == 1)
            #expect(fixture.trace.mojoCompilationCount == 1)
            #expect(fixture.trace.workerCompilationCount == 1)
            try fixture.verifyPublishedState()
            try fixture.verifyCompilationWorkspacesWereRemoved()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsWrongWorkerObjectArchitectureWithoutChangingPublishedOutput()
        throws
    {
        try withWorkerPreparerFixture(
            binaryMode: .wrongWorkerObjectArchitecture
        ) { fixture in
            #expect(
                throws: MojoArtifactError.runtimeObjectArchitectureMismatch(
                    expected: "arm64",
                    actual: "x86_64"
                )
            ) {
                _ = try fixture.prepare()
            }

            #expect(fixture.trace.compilerVersionCount == 1)
            #expect(fixture.trace.mojoCompilationCount == 1)
            #expect(fixture.trace.workerCompilationCount == 1)
            try fixture.verifyPublishedState()
            try fixture.verifyCompilationWorkspacesWereRemoved()
        }
    }
}

private enum WorkerPreparerMutation: Sendable {
    case none
    case generatedHeader
}

private enum WorkerPreparerBinaryMode: Sendable {
    case valid
    case wrongWorkerObjectArchitecture
}

private final class WorkerPreparerInvocationTrace: Sendable {
    private struct State: Sendable {
        var compilerVersionCount = 0
        var mojoCompilationCount = 0
        var workerCompilationCount = 0
        var compilationWorkspaceURLs: [URL] = []
    }

    private let state = Mutex(State())

    var compilerVersionCount: Int {
        state.withLock { $0.compilerVersionCount }
    }

    var mojoCompilationCount: Int {
        state.withLock { $0.mojoCompilationCount }
    }

    var workerCompilationCount: Int {
        state.withLock { $0.workerCompilationCount }
    }

    var compilationWorkspaceURLs: [URL] {
        state.withLock { $0.compilationWorkspaceURLs }
    }

    func recordCompilerVersionRequest() {
        state.withLock { $0.compilerVersionCount += 1 }
    }

    func recordMojoCompilation() {
        state.withLock { $0.mojoCompilationCount += 1 }
    }

    func recordWorkerCompilation(workspaceURL: URL) {
        state.withLock { value in
            value.workerCompilationCount += 1
            value.compilationWorkspaceURLs.append(
                workspaceURL.standardizedFileURL
            )
        }
    }
}

private struct WorkerPreparerFixture {
    private static let publishedContents = Data(
        "previously-published-worker-v1\n".utf8
    )

    let rootURL: URL
    let sourceURL: URL
    let outputURL: URL
    let runtimeLibraryURL: URL
    let identity: MojoArtifactIdentity
    let target: MojoTargetConfiguration
    let trace: WorkerPreparerInvocationTrace
    let preparer: MojoRuntimeWorkerArtifactPreparer

    init(
        rootURL: URL,
        workerMutation: WorkerPreparerMutation,
        binaryMode: WorkerPreparerBinaryMode
    ) throws {
        self.rootURL = rootURL
        sourceURL = rootURL.appendingPathComponent("Bindings.swift")
        try """
        import Mojo

        @mojo
        func add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
            return lhs + rhs
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        identity = try MojoArtifactIdentity(targetName: "WorkerPreparerFixture")
        target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic",
            accelerator: "apple-gpu"
        )
        outputURL = rootURL.appendingPathComponent(
            "PublishedWorker.bundle",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: false
        )
        try Self.publishedContents.write(
            to: outputURL.appendingPathComponent("published.bin")
        )

        runtimeLibraryURL = rootURL.appendingPathComponent(
            "libFixtureRuntime.dylib"
        )
        try Data("runtime-library-v1\n".utf8).write(to: runtimeLibraryURL)

        trace = WorkerPreparerInvocationTrace()
        let processRunner = WorkerPreparerProcessRunner()
        let binaryInspector = WorkerPreparerBinaryInspector(mode: binaryMode)
        let receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: binaryInspector,
            processRunner: processRunner
        )
        let receiptVerifier = MojoRuntimeReceiptVerifier(
            preparer: receiptPreparer
        )
        let runtimeVerifier = MojoRuntimeBundleVerifier(
            binaryInspector: binaryInspector,
            processRunner: processRunner
        )
        let workerVerifier = MojoRuntimeWorkerBundleVerifier(
            runtimeBundleVerifier: runtimeVerifier,
            binaryInspector: binaryInspector,
            processRunner: processRunner
        )
        let runtimeBuilder = MojoRuntimeBundleBuilder(
            linker: WorkerPreparerUnreachableLinker(),
            receiptVerifier: receiptVerifier,
            bundleVerifier: runtimeVerifier
        )
        preparer = MojoRuntimeWorkerArtifactPreparer(
            compiler: WorkerPreparerMojoCompiler(trace: trace),
            workerCompiler: WorkerPreparerCCompiler(
                mutation: workerMutation,
                trace: trace
            ),
            binaryInspector: binaryInspector,
            receiptPreparer: receiptPreparer,
            bundleBuilder: MojoRuntimeWorkerBundleBuilder(
                runtimeBundleBuilder: runtimeBuilder,
                receiptVerifier: receiptVerifier,
                binaryInspector: binaryInspector,
                workerVerifier: workerVerifier
            ),
            bundleVerifier: workerVerifier
        )
    }

    func prepare(
        targets: [MojoTargetConfiguration]? = nil,
        maximumFramePayloadBytes: UInt64 = 4_096
    ) throws -> MojoRuntimeWorkerBundleManifest {
        let options = try MojoPrepareOptions(
            sourceURLs: [sourceURL],
            sourceRootURL: rootURL,
            outputDirectoryURL: outputURL,
            identity: identity,
            targets: targets ?? [target],
            expectedCompilerVersion: WorkerPreparerMojoCompiler.version
        )
        return try preparer.prepare(
            options: options,
            runtimeLibraryURLs: [runtimeLibraryURL],
            executableName: "mojo-worker",
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
    }

    func verifyPublishedState() throws {
        let entries = try FileManager.default.contentsOfDirectory(
            at: outputURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted()
        #expect(entries == ["published.bin"])
        #expect(
            try Data(
                contentsOf: outputURL.appendingPathComponent("published.bin")
            ) == Self.publishedContents
        )
    }

    func verifyCompilationWorkspacesWereRemoved() throws {
        let workspaceURLs = trace.compilationWorkspaceURLs
        #expect(workspaceURLs.count == 1)
        for workspaceURL in workspaceURLs {
            #expect(
                !FileManager.default.fileExists(atPath: workspaceURL.path)
            )
        }
    }
}

private struct WorkerPreparerMojoCompiler: MojoObjectCompiling, Sendable {
    static let version = "Fixture Mojo 1.0"

    let trace: WorkerPreparerInvocationTrace

    func compilerVersion() throws -> String {
        trace.recordCompilerVersionRequest()
        return Self.version
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        trace.recordMojoCompilation()
        let source = try String(
            contentsOfFile: inputPath,
            encoding: .utf8
        )
        guard source.contains("@export(\"") else {
            throw MojoArtifactError.invalidArguments(
                "Worker fixture did not receive generated Mojo exports"
            )
        }
        try Data("mojo-object-v1\n".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        return ""
    }
}

private struct WorkerPreparerCCompiler: MojoRuntimeWorkerCCompiling, Sendable {
    let mutation: WorkerPreparerMutation
    let trace: WorkerPreparerInvocationTrace

    func compile(
        sourceURL: URL,
        includeDirectoryURL: URL,
        outputURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        trace.recordWorkerCompilation(workspaceURL: includeDirectoryURL)
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        guard source.contains("int main(void)") else {
            throw MojoArtifactError.invalidArguments(
                "Worker fixture did not receive generated C entry point"
            )
        }
        try Data("worker-object-v1\n".utf8).write(to: outputURL)

        if mutation == .generatedHeader {
            let headers = try FileManager.default.contentsOfDirectory(
                at: includeDirectoryURL,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "h" }
            guard headers.count == 1, let headerURL = headers.first else {
                throw MojoArtifactError.invalidArguments(
                    "Worker fixture expected exactly one generated header"
                )
            }
            var header = try String(contentsOf: headerURL, encoding: .utf8)
            header.append("\n/* changed during fixture compilation */\n")
            try header.write(
                to: headerURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }
}

private struct WorkerPreparerBinaryInspector: MojoRuntimeBinaryInspecting {
    let mode: WorkerPreparerBinaryMode

    func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        try MojoRegularFile.validate(at: objectURL)
        if mode == .wrongWorkerObjectArchitecture,
           objectURL.lastPathComponent == "RuntimeWorker.o" {
            throw MojoArtifactError.runtimeObjectArchitectureMismatch(
                expected: "arm64",
                actual: "x86_64"
            )
        }
    }

    func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        try MojoRegularFile.validate(at: libraryURL)
        return MojoRuntimeBinaryInspection(
            architecture: "arm64",
            installName: "@rpath/\(libraryURL.lastPathComponent)",
            dynamicDependencies: [],
            exportedSymbols: ["AsyncRT_DeviceContext_create"]
        )
    }

    func inspectExecutable(
        executableURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeExecutableInspection {
        throw MojoArtifactError.invalidArguments(
            "Worker fixture unexpectedly inspected an executable"
        )
    }
}

private struct WorkerPreparerProcessRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == "/usr/bin/nm",
              arguments.count == 2,
              arguments[0] == "-u" else {
            throw MojoArtifactError.invalidArguments(
                "Worker fixture received an unexpected process command"
            )
        }
        return MojoProcessResult(
            status: 0,
            output: "_AsyncRT_DeviceContext_create\n"
        )
    }
}

private struct WorkerPreparerUnreachableLinker: MojoRuntimeExecutableLinking {
    func link(
        objectURLs: [URL],
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String]
    ) throws {
        throw MojoArtifactError.invalidArguments(
            "Worker fixture unexpectedly reached executable linking"
        )
    }
}

private func withWorkerPreparerFixture(
    workerMutation: WorkerPreparerMutation = .none,
    binaryMode: WorkerPreparerBinaryMode = .valid,
    operation: (WorkerPreparerFixture) throws -> Void
) throws {
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "swift-mojo-worker-preparer-test-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: false
    )
    do {
        let fixture = try WorkerPreparerFixture(
            rootURL: rootURL,
            workerMutation: workerMutation,
            binaryMode: binaryMode
        )
        try operation(fixture)
        try FileManager.default.removeItem(at: rootURL)
    } catch {
        let primaryError = error
        do {
            if FileManager.default.fileExists(atPath: rootURL.path) {
                try FileManager.default.removeItem(at: rootURL)
            }
        } catch let cleanupError {
            throw MojoArtifactError.commandFailed(
                command: "clean runtime worker preparer fixture",
                status: -1,
                diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
            )
        }
        throw primaryError
    }
}
