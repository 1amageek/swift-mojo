import Foundation
import MojoArtifactCore
import MojoCommandCore
import Testing

@Suite("swift-mojo command adapter")
struct MojoCommandRunnerTests {
    private let runner = MojoCommandRunner(
        environment: [:],
        currentDirectoryURL: URL(fileURLWithPath: "/tmp")
    )

    @Test(.timeLimit(.minutes(1)))
    func helpDocumentsAuthoringAndReleaseCommands() {
        let result = runner.run(arguments: ["help"])

        #expect(result.exitCode == 0)
        #expect(
            result.standardOutput.contains(
                "swift package --allow-writing-to-package-directory mojo"
            )
        )
        #expect(result.standardOutput.contains("release"))
        #expect(result.standardOutput.contains("runtime-prepare"))
        #expect(result.standardOutput.contains("runtime-verify"))
        #expect(result.standardOutput.contains("runtime-bundle-prepare"))
        #expect(result.standardOutput.contains("runtime-bundle-verify"))
        #expect(result.standardOutput.contains("runtime-library-prepare"))
        #expect(result.standardOutput.contains("runtime-library-verify"))
        #expect(!result.standardOutput.contains("mojo version"))
        #expect(!result.standardOutput.contains("swift-mojo prepare"))
        #expect(result.standardError.isEmpty)
    }

#if os(Linux)
    @Test(.timeLimit(.minutes(1)))
    func nativeLinuxRejectsStaticArtifactAuthoringBeforeMutation() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { removeFixture(output) }

        let result = runner.run(
            arguments: ["init", "--output-dir", output.path]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "Static Mojo artifact authoring requires macOS; Linux is a prepared-artifact consumer platform"
            )
        )
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
#endif

    @Test(.timeLimit(.minutes(1)))
    func runtimeReceiptCommandRequiresAnObject() {
        let result = runner.run(
            arguments: [
                "runtime-prepare",
                "--receipt", "/tmp/RuntimeReceipt.json",
                "--runtime-library", "/tmp/libRuntime.dylib",
                "--target-triple", "arm64-apple-macosx14.0",
                "--target-cpu", "generic",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("Missing required option --object"))
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeReceiptCommandCannotOverwriteItsObject() {
        let result = runner.run(
            arguments: [
                "runtime-prepare",
                "--object", "/tmp/RuntimeObject.o",
                "--receipt", "/tmp/RuntimeObject.o",
                "--runtime-library", "/tmp/libRuntime.dylib",
                "--target-triple", "arm64-apple-macosx14.0",
                "--target-cpu", "generic",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "--receipt must not overwrite the object or a runtime library"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeBundleCommandRequiresAnExecutableName() {
        let result = runner.run(
            arguments: [
                "runtime-bundle-prepare",
                "--object", "/tmp/RuntimeObject.o",
                "--receipt", "/tmp/RuntimeReceipt.json",
                "--runtime-library", "/tmp/libRuntime.dylib",
                "--output", "/tmp/Runtime.bundle",
                "--target-triple", "arm64-apple-macosx14.0",
                "--target-cpu", "generic",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "Missing required option --executable-name"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeLibraryCommandRequiresAnAccelerator() {
        let result = runner.run(
            arguments: [
                "runtime-library-prepare",
                "--source", "/tmp/Bindings.swift",
                "--output", "/tmp/RuntimeLibrary.bundle",
                "--runtime-library", "/tmp/libRuntime.dylib",
                "--target-triple", "arm64-apple-macosx14.0",
                "--target-cpu", "generic",
                "--format", "json",
            ]
        )

        #expect(result.exitCode == 1)
        #expect(
            result.standardOutput.contains(
                "runtime-library-prepare requires --target-accelerator"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func recoveryDiagnosticsUsePublicPackageCommand() {
        let diagnostic = MojoArtifactError.manifestMissing(
            "/tmp/MojoArtifact.json"
        ).description

        #expect(
            diagnostic.contains(
                "swift package --disable-sandbox --allow-writing-to-package-directory mojo prepare"
            )
        )
        #expect(!diagnostic.contains("Run 'swift-mojo prepare'"))
    }

    @Test(.timeLimit(.minutes(1)))
    func packageVersionIsNotExposedByInternalCommand() {
        let result = runner.run(arguments: ["version"])

        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("Unknown command 'version'"))
    }

    @Test(.timeLimit(.minutes(1)))
    func unknownCommandReturnsMachineReadableFailure() throws {
        let result = runner.run(
            arguments: ["unknown", "--format", "json"]
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(result.standardOutput.utf8)
        ) as? [String: Any]

        #expect(result.exitCode != 0)
        #expect(object?["success"] as? Bool == false)
        #expect(result.standardError.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func unsupportedOutputFormatFailsExplicitly() {
        let result = runner.run(
            arguments: ["help", "--format", "yaml"]
        )

        #expect(result.exitCode != 0)
        #expect(result.standardError.contains("Unsupported --format"))
    }

    @Test(.timeLimit(.minutes(1)))
    func releaseFailurePreservesMachineReadableContract() throws {
        let result = runner.run(
            arguments: [
                "release",
                "--package-root", "/tmp/missing-swift-mojo-package",
                "--target", "Model",
                "--format", "json",
            ]
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(result.standardOutput.utf8)
        ) as? [String: Any]

        #expect(result.exitCode != 0)
        #expect(object?["success"] as? Bool == false)
        #expect(object?["command"] as? String == "release")
        #expect(result.standardError.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func inspectUsesOnlyPluginResolvedSourceInventory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let included = root.appendingPathComponent(
            "Implementation/API/Bindings.swift"
        )
        let excluded = root.appendingPathComponent(
            "Implementation/Excluded.swift"
        )
        try FileManager.default.createDirectory(
            at: included.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        defer {
            do {
                try FileManager.default.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove source inventory fixture: \(error)")
            }
        }
        try "// swift-tools-version: 6.2".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return a + b
        }
        """.write(to: included, atomically: true, encoding: .utf8)
        try "@mojo func excluded() -> String".write(
            to: excluded,
            atomically: true,
            encoding: .utf8
        )
        let packageRunner = MojoCommandRunner(
            environment: [:],
            currentDirectoryURL: root
        )

        let result = packageRunner.run(
            arguments: [
                "inspect",
                "--package-root", root.path,
                "--target", "Application",
                "--source-root", root.path,
                "--source", included.path,
            ]
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.contains("Inspected 1 binding(s)"))
        #expect(!result.standardOutput.contains("excluded"))
    }

    @Test(.timeLimit(.minutes(1)))
    func packageCommandsRejectMissingPluginSourceInventory() {
        let result = runner.run(
            arguments: [
                "inspect",
                "--package-root", "/tmp",
                "--target", "Application",
            ]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "MojoCommandPlugin must supply SwiftPM-resolved --source paths"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func packageCommandsRejectDuplicatePluginSourcePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bindings.swift")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { removeFixture(root) }
        try "// swift-tools-version: 6.2".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        try "@mojo func add(_ a: Int32, _ b: Int32) -> Int32 { a + b }".write(
            to: source,
            atomically: true,
            encoding: .utf8
        )
        let packageRunner = MojoCommandRunner(
            environment: [:],
            currentDirectoryURL: root
        )

        let result = packageRunner.run(
            arguments: [
                "inspect",
                "--package-root", root.path,
                "--target", "Application",
                "--source-root", root.path,
                "--source", source.path,
                "--source", source.path,
            ]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "SwiftPM source inventory contains duplicate paths"
            )
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func packageCommandsRejectPluginSourceOutsidePackageRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let outsideSource = root.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).swift")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { removeFixture(root) }
        try "// swift-tools-version: 6.2".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        let packageRunner = MojoCommandRunner(
            environment: [:],
            currentDirectoryURL: root
        )

        let result = packageRunner.run(
            arguments: [
                "inspect",
                "--package-root", root.path,
                "--target", "Application",
                "--source-root", root.path,
                "--source", outsideSource.path,
            ]
        )

        #expect(result.exitCode != 0)
        #expect(
            result.standardError.contains(
                "SwiftPM source inventory must contain only package-owned Swift files"
            )
        )
    }

    private func removeFixture(_ root: URL) {
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        do {
            try FileManager.default.removeItem(at: root)
        } catch {
            Issue.record("Failed to remove command fixture: \(error)")
        }
    }
}
