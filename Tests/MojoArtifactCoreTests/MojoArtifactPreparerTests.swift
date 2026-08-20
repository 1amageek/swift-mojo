import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

private struct FixtureMojoCompiler: MojoObjectCompiling {
    func compilerVersion() throws -> String {
        "fixture-mojo 1.0"
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration
    ) throws -> String {
        try Data("fixture object".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        return ""
    }
}

private struct FixturePackagingRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        switch executablePath {
        case "/usr/bin/ar":
            guard arguments.count == 3 else {
                throw MojoArtifactError.invalidArguments("Unexpected ar arguments")
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: arguments[2]),
                to: URL(fileURLWithPath: arguments[1])
            )
        case "/usr/bin/xcrun":
            try createXCFramework(arguments: arguments)
        default:
            throw MojoArtifactError.invalidArguments(
                "Unexpected fixture command: \(executablePath)"
            )
        }
        return MojoProcessResult(status: 0, output: "")
    }

    private func createXCFramework(arguments: [String]) throws {
        let archive = try requiredValue(after: "-library", in: arguments)
        let headers = try requiredValue(after: "-headers", in: arguments)
        let output = try requiredValue(after: "-output", in: arguments)
        let artifactURL = URL(fileURLWithPath: output, isDirectory: true)
        let sliceURL = artifactURL.appendingPathComponent(
            "macos-arm64",
            isDirectory: true
        )
        let destinationHeaders = sliceURL.appendingPathComponent(
            "Headers",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: destinationHeaders,
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: archive),
            to: sliceURL.appendingPathComponent(MojoStaticABI.libraryName)
        )
        for name in ["GeneratedMojoABI.h", "module.modulemap"] {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: headers).appendingPathComponent(name),
                to: destinationHeaders.appendingPathComponent(name)
            )
        }
        try Data("fixture plist".utf8).write(
            to: artifactURL.appendingPathComponent("Info.plist")
        )
    }

    private func requiredValue(
        after option: String,
        in arguments: [String]
    ) throws -> String {
        guard let optionIndex = arguments.firstIndex(of: option) else {
            throw MojoArtifactError.invalidArguments(
                "Missing fixture option \(option)"
            )
        }
        let valueIndex = arguments.index(after: optionIndex)
        guard valueIndex < arguments.endIndex else {
            throw MojoArtifactError.invalidArguments(
                "Missing fixture value for \(option)"
            )
        }
        return arguments[valueIndex]
    }
}

@Suite("Mojo artifact preparation")
struct MojoArtifactPreparerTests {
    @Test(.timeLimit(.minutes(1)))
    func generationPipelineChangeInvalidatesCache() throws {
        try withPreparerFixture { fixture in
            let firstPreparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-a"
            )
            let first = try firstPreparer.prepare(options: fixture.options)
            let reused = try firstPreparer.prepare(options: fixture.options)
            let changedPreparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-b"
            )
            let regenerated = try changedPreparer.prepare(options: fixture.options)

            #expect(first.disposition == .prepared)
            #expect(reused.disposition == .reused)
            #expect(regenerated.disposition == .prepared)
            #expect(regenerated.manifest.generationPipelineDigest == "pipeline-b")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verifierRejectsDifferentGenerationPipeline() throws {
        try withPreparerFixture { fixture in
            let preparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-a"
            )
            _ = try preparer.prepare(options: fixture.options)
            let verifier = MojoArtifactVerifier(
                generationPipelineDigest: "pipeline-b"
            )
            let generated = fixture.root.appendingPathComponent("Registry.swift")

            #expect(
                throws: MojoArtifactError.generationPipelineMismatch(
                    expected: "pipeline-b",
                    actual: "pipeline-a"
                )
            ) {
                _ = try verifier.verify(
                    options: MojoVerifyOptions(
                        sourceURLs: [fixture.sourceURL],
                        outputDirectoryURL: fixture.outputDirectory,
                        generatedSourceURL: generated,
                        targetTriple: "arm64-apple-macosx14.0",
                        targetCPU: "generic"
                    )
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func outputLockSerializesConcurrentCriticalSections() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove lock fixture: \(error)")
            }
        }
        let output = root.appendingPathComponent("Generated", isDirectory: true)
        let stateURL = root.appendingPathComponent("state.txt")
        let transaction = MojoOutputTransaction()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<8 {
                group.addTask {
                    let taskFileManager = FileManager.default
                    try transaction.withExclusiveAccess(to: output) { _ in
                        var state: Data
                        if taskFileManager.fileExists(atPath: stateURL.path) {
                            state = try Data(contentsOf: stateURL)
                        } else {
                            state = Data()
                        }
                        state.append(Data("\(value)\n".utf8))
                        try state.write(to: stateURL, options: .atomic)
                    }
                }
            }
            try await group.waitForAll()
        }

        let lines = try String(contentsOf: stateURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 8)
        #expect(Set(lines).count == 8)
    }
}

private struct PreparerFixture {
    let root: URL
    let sourceURL: URL
    let outputDirectory: URL
    let options: MojoPrepareOptions

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceURL = root.appendingPathComponent("Bindings.swift")
        outputDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            mojo { return a + b }
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        options = try MojoPrepareOptions(
            sourceURLs: [sourceURL],
            outputDirectoryURL: outputDirectory,
            targetTriple: "arm64-apple-macosx14.0",
            targetCPU: "generic"
        )
    }
}

private func withPreparerFixture(
    _ body: (PreparerFixture) throws -> Void
) throws {
    let fixture = try PreparerFixture()
    defer {
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            Issue.record("Failed to remove preparer fixture: \(error)")
        }
    }
    try body(fixture)
}
