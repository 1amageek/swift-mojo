import Foundation
import MojoPOSIXSupport
import Testing
@testable import MojoCompilerCore

private struct FixedMojoExecutableLocator: MojoExecutableLocating {
    let path: String

    func locate() throws -> String {
        path
    }
}

private enum MockBuildBehavior: Sendable {
    case producesArtifact
    case omitsArtifact
    case fails
}

private struct MockMojoProcessRunner: MojoProcessRunning {
    let outputPath: String
    let behavior: MockBuildBehavior

    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        #expect(executablePath == "/mock/mojo")

        if arguments == ["--version"] {
            return MojoProcessResult(status: 0, output: "mojo 1.0.0\n")
        }

        #expect(arguments.contains("--target-triple"))
        #expect(arguments.contains("arm64-apple-macosx14.0"))
        #expect(arguments.contains("--target-cpu"))
        #expect(arguments.contains("apple-m1"))
        #expect(arguments == [
            "build",
            "--emit", "object",
            "--target-triple", "arm64-apple-macosx14.0",
            "--target-cpu", "apple-m1",
            "-o", outputPath,
            "/tmp/Bindings.mojo",
        ])

        switch behavior {
        case .producesArtifact:
            _ = FileManager.default.createFile(
                atPath: outputPath,
                contents: Data()
            )
            return MojoProcessResult(
                status: 0,
                output: "compiler diagnostic\n"
            )
        case .omitsArtifact:
            return MojoProcessResult(status: 0, output: "")
        case .fails:
            return MojoProcessResult(status: 7, output: "compile failed")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func compilerEmitsTargetAwareObject() throws {
    try withTemporaryDirectory { directory in
        let output = directory.appendingPathComponent("Bindings.o")
        let target = try makeTarget()
        let compiler = try MojoCompiler(
            executableLocator: FixedMojoExecutableLocator(
                path: "/mock/mojo"
            ),
            processRunner: MockMojoProcessRunner(
                outputPath: output.path,
                behavior: .producesArtifact
            )
        )

        let diagnostic = try compiler.compileObject(
            inputPath: "/tmp/Bindings.mojo",
            outputPath: output.path,
            target: target
        )

        #expect(diagnostic == "compiler diagnostic\n")
        #expect(FileManager.default.fileExists(atPath: output.path))
        #expect(try compiler.compilerVersion() == "mojo 1.0.0")
    }
}

@Test(.timeLimit(.minutes(1)))
func compilerPreservesCommandFailureDiagnostic() throws {
    try withTemporaryDirectory { directory in
        let output = directory.appendingPathComponent("Bindings.o")
        let compiler = try MojoCompiler(
            executableLocator: FixedMojoExecutableLocator(
                path: "/mock/mojo"
            ),
            processRunner: MockMojoProcessRunner(
                outputPath: output.path,
                behavior: .fails
            )
        )

        do {
            _ = try compiler.compileObject(
                inputPath: "/tmp/Bindings.mojo",
                outputPath: output.path,
                target: makeTarget()
            )
            Issue.record("Expected compiler failure")
        } catch let error as MojoCompilerToolError {
            guard case .commandFailed(
                _,
                let status,
                let diagnostic
            ) = error else {
                Issue.record("Unexpected compiler error: \(error)")
                return
            }
            #expect(status == 7)
            #expect(diagnostic == "compile failed")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func compilerRejectsMissingArtifactAfterSuccessfulProcess() throws {
    try withTemporaryDirectory { directory in
        let output = directory.appendingPathComponent("Bindings.o")
        _ = FileManager.default.createFile(
            atPath: output.path,
            contents: Data("stale".utf8)
        )
        let compiler = try MojoCompiler(
            executableLocator: FixedMojoExecutableLocator(
                path: "/mock/mojo"
            ),
            processRunner: MockMojoProcessRunner(
                outputPath: output.path,
                behavior: .omitsArtifact
            )
        )

        #expect(
            throws: MojoCompilerToolError.artifactNotProduced(output.path)
        ) {
            _ = try compiler.compileObject(
                inputPath: "/tmp/Bindings.mojo",
                outputPath: output.path,
                target: makeTarget()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerCapturesProcessOutput() throws {
    let result = try FoundationMojoProcessRunner(
        timeoutSeconds: 5,
        terminationGraceSeconds: 1
    ).capture(
        executablePath: "/bin/sh",
        arguments: ["-c", "printf 'mojo-output'"]
    )

    #expect(result.status == 0)
    #expect(result.output == "mojo-output")
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerPreservesNonzeroExitStatusAndDiagnostic() throws {
    let result = try FoundationMojoProcessRunner(
        timeoutSeconds: 5,
        terminationGraceSeconds: 1
    ).capture(
        executablePath: "/bin/sh",
        arguments: ["-c", "printf 'failed-output'; exit 42"]
    )

    #expect(result.status == 42)
    #expect(result.output == "failed-output")
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerClassifiesExecutableLaunchFailure() throws {
    do {
        _ = try FoundationMojoProcessRunner(
            timeoutSeconds: 5,
            terminationGraceSeconds: 1
        ).capture(
            executablePath: "/swift-mojo-fixture/missing-executable",
            arguments: []
        )
        Issue.record("Missing executable unexpectedly launched")
    } catch let error as MojoCompilerToolError {
        guard case .processLaunchFailed(let command, let message) = error else {
            Issue.record("Unexpected process error: \(error)")
            return
        }
        #expect(command == "/swift-mojo-fixture/missing-executable")
        #expect(!message.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerObservesExitAtTheTimeoutBoundary() throws {
    let result = try FoundationMojoProcessRunner(
        timeoutSeconds: 1,
        terminationGraceSeconds: 1,
        pollInterval: 2
    ).capture(
        executablePath: "/bin/sh",
        arguments: ["-c", "sleep 0.1"]
    )

    #expect(result.status == 0)
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerRejectsExitAfterTheTimeoutBoundary() throws {
    do {
        _ = try FoundationMojoProcessRunner(
            timeoutSeconds: 1,
            terminationGraceSeconds: 1,
            pollInterval: 2
        ).capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 1.5"]
        )
        Issue.record("Late process exit unexpectedly succeeded")
    } catch let error as MojoCompilerToolError {
        guard case .processTimedOut(_, let seconds, _) = error else {
            Issue.record("Unexpected process error: \(error)")
            return
        }
        #expect(seconds == 1)
    }
}

@Test(.timeLimit(.minutes(1)))
func foundationRunnerTimesOutAndTerminatesDescendants() throws {
    do {
        _ = try FoundationMojoProcessRunner(
            timeoutSeconds: 1,
            terminationGraceSeconds: 1
        ).capture(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30 & child=$!; echo $child; wait"]
        )
        Issue.record("Hanging process unexpectedly completed")
    } catch let error as MojoCompilerToolError {
        guard case .processTimedOut(_, let seconds, let diagnostic) = error else {
            Issue.record("Unexpected process error: \(error)")
            return
        }
        #expect(seconds == 1)
        let childProcessID = try #require(
            diagnostic.split(whereSeparator: { $0.isNewline }).first
                .flatMap { MojoPOSIXSupport.ProcessID($0) }
        )
        #expect(processDisappears(childProcessID, within: .seconds(5)))
    }
}

private func makeTarget() throws -> MojoTargetConfiguration {
    try MojoTargetConfiguration(
        triple: "arm64-apple-macosx14.0",
        cpu: "apple-m1"
    )
}

private func processDisappears(
    _ processID: MojoPOSIXSupport.ProcessID,
    within duration: Duration
) -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: duration)
    repeat {
        if !MojoPOSIXSupport.processIsAlive(processID) {
            return true
        }
        Thread.sleep(forTimeInterval: 0.02)
    } while clock.now < deadline

    return !MojoPOSIXSupport.processIsAlive(processID)
}

private func withTemporaryDirectory(
    _ body: (URL) throws -> Void
) throws {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    defer {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            Issue.record("Failed to remove compiler fixture: \(error)")
        }
    }

    try body(directory)
}
