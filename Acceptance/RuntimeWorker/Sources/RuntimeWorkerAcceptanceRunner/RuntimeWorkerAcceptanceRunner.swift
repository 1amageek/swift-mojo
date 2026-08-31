import Foundation
import RuntimeWorkerAcceptance

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@main
enum RuntimeWorkerAcceptanceRunner {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--source-digest-at" {
            try writeSourceDigest(arguments: arguments)
            return
        }
        if arguments.first == "--snapshot-source-at" {
            try writeSnapshotDigest(arguments: arguments)
            return
        }
        if arguments.first == "--execute-verified-source-at" {
            try executeVerifiedSource(arguments: arguments)
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

    private static func writeSnapshotDigest(arguments: [String]) throws {
        guard arguments.count == 4,
            arguments[2] == "--destination"
        else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--snapshot-source-at requires a source root and --destination path"
            )
        }
        let snapshot = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter()
            .materializeVerifiedSnapshot(
                from: URL(fileURLWithPath: arguments[1]),
                at: URL(fileURLWithPath: arguments[3])
            )
        FileHandle.standardOutput.write(Data(snapshot.identity.digest.utf8))
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func executeVerifiedSource(arguments: [String]) throws {
        guard arguments.count >= 7,
            arguments[2] == "--destination",
            arguments[4] == "--live-git-root",
            arguments[6] == "--"
        else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "--execute-verified-source-at requires source, destination, live Git root, and --"
            )
        }
        let destination = URL(fileURLWithPath: arguments[3])
            .standardizedFileURL
        guard destination.lastPathComponent == "acceptance-source" else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "verified source destination must be named acceptance-source"
            )
        }
        let snapshot = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter()
            .materializeVerifiedSnapshot(
                from: URL(fileURLWithPath: arguments[1]),
                at: destination
            )
        guard
            let script = String(
                data: snapshot.executionScriptContents,
                encoding: .utf8
            ),
            !script.utf8.contains(0)
        else {
            throw RuntimeWorkerAcceptanceRunnerError
                .invalidVerifiedExecutionScript
        }
        let liveGitRoot = URL(fileURLWithPath: arguments[5])
            .standardizedFileURL
        let bashArguments =
            [
                "/bin/bash",
                "-c",
                script,
                "swift-mojo-runtime-worker-acceptance-verified-v1",
                snapshot.rootURL.path,
                liveGitRoot.path,
                snapshot.identity.digest,
            ] + Array(arguments.dropFirst(7))
        try replaceCurrentProcess(arguments: bashArguments)
    }

    private static func replaceCurrentProcess(arguments: [String]) throws {
        guard arguments.allSatisfy({ !$0.utf8.contains(0) }) else {
            throw RuntimeWorkerAcceptanceRunnerError
                .invalidVerifiedExecutionScript
        }
        // Each strdup allocation is an initialized, NUL-terminated C string
        // owned only by this synchronous process-replacement scope. The pointer
        // array borrows those allocations solely for execv, never escapes or
        // crosses a Sendable boundary, and defer frees every allocation exactly
        // once if execv returns. strdup supplies CChar alignment and execv only
        // reads the initialized bytes through the terminating NUL.
        var allocatedArguments: [UnsafeMutablePointer<CChar>] = []
        allocatedArguments.reserveCapacity(arguments.count)
        defer {
            for argument in allocatedArguments {
                free(argument)
            }
        }
        for argument in arguments {
            guard let allocated = strdup(argument) else {
                throw
                    RuntimeWorkerAcceptanceRunnerError
                    .processReplacementFailed("argument allocation failed")
            }
            allocatedArguments.append(allocated)
        }
        var pointers = allocatedArguments.map(Optional.some)
        pointers.append(nil)
        _ = "/bin/bash".withCString { executable in
            pointers.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else {
                    errno = EINVAL
                    return -1
                }
                return execv(executable, baseAddress)
            }
        }
        let failureCode = errno
        throw RuntimeWorkerAcceptanceRunnerError.processReplacementFailed(
            "errno=\(failureCode) \(String(cString: strerror(failureCode)))"
        )
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
