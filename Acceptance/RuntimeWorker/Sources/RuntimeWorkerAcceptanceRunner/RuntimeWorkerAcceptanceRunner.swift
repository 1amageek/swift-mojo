import Foundation
import RuntimeWorkerAcceptance
import RuntimeWorkerAcceptanceSourceIdentity

@main
enum RuntimeWorkerAcceptanceRunner {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--source-digest-at" {
            try writeSourceDigest(arguments: arguments)
            return
        }
        let configuration = try configuration(arguments: arguments)
        let report = try await RuntimeWorkerAcceptanceController().run(
            configuration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func configuration(
        arguments: [String]
    ) throws -> RuntimeWorkerAcceptanceRunConfiguration {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard Self.valueOptions.contains(option) else {
                throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                    "unknown option \(option)"
                )
            }
            guard index + 1 < arguments.count,
                !arguments[index + 1].hasPrefix("--")
            else {
                throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                    "missing value for \(option)"
                )
            }
            guard values[option] == nil else {
                throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                    "repeated option \(option)"
                )
            }
            values[option] = arguments[index + 1]
            index += 2
        }

        guard let bundlePath = values["--bundle"] else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--bundle is required"
            )
        }
        guard let consumerPath = values["--consumer"] else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--consumer is required"
            )
        }
        guard let repositoryRootPath = values["--repository-root"] else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--repository-root is required"
            )
        }
        guard let expectedSourceDigest = values["--expected-source-digest"] else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--expected-source-digest is required"
            )
        }
        guard let swiftMojoRevision = values["--swift-mojo-revision"] else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--swift-mojo-revision is required"
            )
        }

        let temporaryPath =
            values["--tmpdir"]
            ?? ProcessInfo.processInfo.environment["TMPDIR"]
            ?? FileManager.default.temporaryDirectory.path
        let deadlineSeconds: Int64
        if let raw = values["--deadline-seconds"] {
            guard let parsed = Int64(raw), parsed > 0 else {
                throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                    "--deadline-seconds must be a positive integer"
                )
            }
            deadlineSeconds = parsed
        } else {
            deadlineSeconds = 45
        }

        return try RuntimeWorkerAcceptanceRunConfiguration(
            bundleURL: URL(fileURLWithPath: bundlePath),
            failureBundleURL: values["--failure-bundle"].map {
                URL(fileURLWithPath: $0)
            },
            consumerExecutableURL: URL(fileURLWithPath: consumerPath),
            temporaryDirectoryURL: URL(fileURLWithPath: temporaryPath),
            repositoryRootURL: URL(fileURLWithPath: repositoryRootPath),
            expectedSourceDigest: expectedSourceDigest,
            swiftMojoRevision: swiftMojoRevision,
            consumerDeadline: .seconds(deadlineSeconds)
        )
    }

    private static func writeSourceDigest(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--source-digest-at requires exactly one repository root"
            )
        }
        let identity = try FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier()
            .sourceIdentity(at: URL(fileURLWithPath: arguments[1]))
        FileHandle.standardOutput.write(Data(identity.digest.utf8))
        FileHandle.standardOutput.write(Data([10]))
    }

    private static let valueOptions: Set<String> = [
        "--bundle",
        "--failure-bundle",
        "--consumer",
        "--tmpdir",
        "--deadline-seconds",
        "--repository-root",
        "--expected-source-digest",
        "--swift-mojo-revision",
    ]
}
