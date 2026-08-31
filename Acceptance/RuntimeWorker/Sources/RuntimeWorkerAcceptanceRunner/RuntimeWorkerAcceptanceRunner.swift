import Foundation
import RuntimeWorkerAcceptance

@main
enum RuntimeWorkerAcceptanceRunner {
    static func main() async throws {
        let configuration = try configuration(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
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
                  !arguments[index + 1].hasPrefix("--") else {
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

        let temporaryPath = values["--tmpdir"]
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
            consumerDeadline: .seconds(deadlineSeconds)
        )
    }

    private static let valueOptions: Set<String> = [
        "--bundle",
        "--failure-bundle",
        "--consumer",
        "--tmpdir",
        "--deadline-seconds",
    ]
}
