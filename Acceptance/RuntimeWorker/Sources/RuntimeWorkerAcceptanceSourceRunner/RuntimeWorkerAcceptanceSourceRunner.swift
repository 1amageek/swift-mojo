import Foundation
import RuntimeWorkerAcceptanceSourceIdentity

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// Provides the source-authority operations used before the runtime runner is
/// built from the verified source snapshot.
@main
enum RuntimeWorkerAcceptanceSourceRunner {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "--source-digest-at":
            try writeSourceDigest(arguments: arguments)
        case "--snapshot-source-at":
            try writeSnapshotDigest(arguments: arguments)
        case "--execute-verified-source-at":
            try executeVerifiedSource(arguments: arguments)
        default:
            throw RuntimeWorkerAcceptanceSourceRunnerError.invalidInput(
                "expected --source-digest-at, --snapshot-source-at, or --execute-verified-source-at"
            )
        }
    }

    private static func writeSourceDigest(arguments: [String]) throws {
        guard arguments.count == 2 else {
            throw RuntimeWorkerAcceptanceSourceRunnerError.invalidInput(
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
            throw RuntimeWorkerAcceptanceSourceRunnerError.invalidInput(
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
            throw RuntimeWorkerAcceptanceSourceRunnerError.invalidInput(
                "--execute-verified-source-at requires source, destination, live Git root, and --"
            )
        }
        let destination = URL(fileURLWithPath: arguments[3])
            .standardizedFileURL
        guard destination.lastPathComponent == "acceptance-source" else {
            throw RuntimeWorkerAcceptanceSourceRunnerError.invalidInput(
                "verified source destination must be named acceptance-source"
            )
        }
        let snapshot = try FileSystemRuntimeWorkerAcceptanceSourceSnapshotter()
            .materializeVerifiedSnapshot(
                from: URL(fileURLWithPath: arguments[1]),
                at: destination
            )
        let scriptData = snapshot.executionScriptContents
        guard !scriptData.contains(0),
            let script = String(data: scriptData, encoding: .utf8),
            script.data(using: .utf8) == scriptData
        else {
            throw RuntimeWorkerAcceptanceSourceRunnerError
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
            throw RuntimeWorkerAcceptanceSourceRunnerError
                .invalidVerifiedExecutionScript
        }

        // Each strdup allocation is an initialized, NUL-terminated C string
        // owned only by this synchronous process-replacement scope. The pointer
        // array borrows those allocations solely for execv, never escapes or
        // crosses a Sendable boundary, and defer frees every allocation exactly
        // once if execv returns. strdup supplies CChar alignment and execv only
        // reads initialized bytes through the terminating NUL.
        var allocatedArguments: [UnsafeMutablePointer<CChar>] = []
        allocatedArguments.reserveCapacity(arguments.count)
        defer {
            for argument in allocatedArguments {
                free(argument)
            }
        }
        for argument in arguments {
            guard let allocated = strdup(argument) else {
                throw RuntimeWorkerAcceptanceSourceRunnerError
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
        throw RuntimeWorkerAcceptanceSourceRunnerError
            .processReplacementFailed(
                "errno=\(failureCode) \(String(cString: strerror(failureCode)))"
            )
    }
}
