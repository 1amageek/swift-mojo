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
        #expect(!result.standardOutput.contains("swift-mojo prepare"))
        #expect(result.standardError.isEmpty)
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
    func versionHasMachineReadableOutput() throws {
        let result = runner.run(
            arguments: ["version", "--format", "json"]
        )
        let object = try JSONSerialization.jsonObject(
            with: Data(result.standardOutput.utf8)
        ) as? [String: Any]

        #expect(result.exitCode == 0)
        #expect(object?["success"] as? Bool == true)
        #expect(object?["command"] as? String == "version")
        #expect(object?["message"] as? String == SwiftMojoVersion.current)
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
            arguments: ["version", "--format", "yaml"]
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
}
