import Foundation
import MojoRuntime
import MojoRuntimeWorker

@main
struct RuntimeWorkerAcceptanceConsumer {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let bundleURL = try requiredURL("--bundle", arguments: arguments)
        let failureBundleURL = try optionalURL(
            "--failure-bundle",
            arguments: arguments
        ) ?? bundleURL
        let executionPathIsolated = try requireCleanExecutionEnvironment()

        let first = try await runSuccessfulAttempt(at: bundleURL)
        let forced = try await runForcedFailureAttempt(at: failureBundleURL)
        let third = try await runSuccessfulAttempt(at: bundleURL)
        let report = ConsumerRunReport(
            firstAttemptOutputBitPatterns: first,
            forcedFailureError: forced.errorCode,
            forcedFailureTimedOut: forced.timedOut,
            forcedFailurePartialOutputElementCount: forced.partialOutputCount,
            forcedFailureCleanupFailureCount: forced.cleanupFailureCount,
            thirdAttemptOutputBitPatterns: third,
            executionPathIsolated: executionPathIsolated,
            cleanEnvironmentObserved: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }

    private static func runSuccessfulAttempt(at bundleURL: URL) async throws
        -> [UInt32]
    {
        let verification = try FileSystemMojoRuntimeWorkerBundleVerifier(
            environment: [:]
        ).verifyWorkerBundle(at: bundleURL)
        let worker = try MojoRuntimeWorker(verification: verification)
        let factory = try worker.sessionFactory(
            for: try requiredBinding(named: "createSession", in: verification)
        )
        let operation = try worker.float32Operation(
            for: try requiredBinding(named: "scale", in: verification)
        )
        let output = try await worker.withAttempt(
            sessionFactory: factory,
            requirements: .init(
                device: .cpu,
                requiredCapabilities: [
                    .synchronousInvocation,
                    .hostAccessibleMemory,
                    .float32,
                ]
            ),
            timeouts: Self.timeouts
        ) { session in
            try await session.invoke(
                operation,
                input: [1, 2, 3],
                outputElementCount: 3,
                timeout: .seconds(2)
            )
        }
        let bitPatterns = output.map { (value: Float) in value.bitPattern }
        guard bitPatterns == Self.expectedOutputBitPatterns else {
            throw ConsumerError.unexpectedOutput(bitPatterns)
        }
        return bitPatterns
    }

    private static func runForcedFailureAttempt(at bundleURL: URL) async throws
        -> ForcedFailureResult
    {
        let verification = try FileSystemMojoRuntimeWorkerBundleVerifier(
            environment: [:]
        ).verifyWorkerBundle(at: bundleURL)
        let worker = try MojoRuntimeWorker(verification: verification)
        let factory = try worker.sessionFactory(
            for: try requiredBinding(named: "createSession", in: verification)
        )
        let operation = try worker.float32Operation(
            for: try requiredBinding(named: "stall", in: verification)
        )

        do {
            let _: [Float] = try await worker.withAttempt(
                sessionFactory: factory,
                requirements: .init(
                    device: .cpu,
                    requiredCapabilities: [
                        .synchronousInvocation,
                        .hostAccessibleMemory,
                        .float32,
                    ]
                ),
                timeouts: Self.timeouts
            ) { session in
                try await session.invoke(
                    operation,
                    input: [1],
                    outputElementCount: 1,
                    timeout: .milliseconds(100)
                )
            }
            throw ConsumerError.stallUnexpectedlyReturned
        } catch let error as MojoRuntimeWorkerError {
            guard case .invocationTimedOut = error else {
                throw ConsumerError.unexpectedForcedFailure(error.description)
            }
            return ForcedFailureResult(
                errorCode: "invocationTimedOut",
                timedOut: true,
                partialOutputCount: 0,
                cleanupFailureCount: 0
            )
        }
    }

    private static func requiredBinding(
        named name: String,
        in verification: MojoRuntimeWorkerBundleVerification
    ) throws -> MojoRuntimeWorkerBinding {
        guard let binding = verification.bindings.first(where: {
            $0.functionName == name
        }) else {
            throw ConsumerError.missingBinding(name)
        }
        return binding
    }

    private static func requireCleanExecutionEnvironment() throws -> Bool {
        let environment = ProcessInfo.processInfo.environment
        let forbiddenExact = [
            "MODULAR_HOME",
            "SWIFT_MOJO_EXECUTABLE",
            "SWIFT_MOJO_LLVM_AR",
            "PYTHONHOME",
            "PYTHONPATH",
        ]
        let forbidden = Set(
            forbiddenExact.filter { environment[$0] != nil }
                + environment.keys.filter {
                    $0.hasPrefix("DYLD_") || $0.hasPrefix("LD_")
                }
        )
        guard forbidden.isEmpty else {
            throw ConsumerError.dirtyEnvironment(forbidden.sorted())
        }

        let pathEntries = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        let unavailableNames = ["mojo", "swift", "python", "python3"]
        let availableTools = pathEntries.flatMap { entry in
            unavailableNames.filter {
                FileManager.default.isExecutableFile(
                    atPath: URL(fileURLWithPath: entry)
                        .appendingPathComponent($0)
                        .path
                )
            }
        }
        guard availableTools.isEmpty else {
            throw ConsumerError.compilerOrPythonAvailable(availableTools)
        }
        return true
    }

    private static func requiredURL(
        _ option: String,
        arguments: [String]
    ) throws -> URL {
        guard let value = try optionValue(option, arguments: arguments) else {
            throw ConsumerError.missingArgument(option)
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func optionalURL(
        _ option: String,
        arguments: [String]
    ) throws -> URL? {
        guard let value = try optionValue(option, arguments: arguments) else {
            return nil
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private static func optionValue(
        _ option: String,
        arguments: [String]
    ) throws -> String? {
        let matches = arguments.enumerated().compactMap {
            (index: Int, argument: String) -> String? in
            guard argument == option, index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        guard matches.count <= 1 else {
            throw ConsumerError.repeatedArgument(option)
        }
        if let value = matches.first, !value.hasPrefix("--") {
            return value
        }
        return nil
    }

    private static let timeouts: MojoRuntimeWorkerTimeouts = {
        do {
            return try MojoRuntimeWorkerTimeouts(
                startup: .seconds(5),
                sessionCreation: .seconds(5),
                gracefulShutdown: .seconds(5),
                terminationGracePeriod: .seconds(1),
                forcedCleanup: .seconds(5)
            )
        } catch {
            preconditionFailure("fixed acceptance timeouts are invalid: \(error)")
        }
    }()

    private static let expectedOutputBitPatterns: [UInt32] = [
        Float(2).bitPattern,
        Float(4).bitPattern,
        Float(6).bitPattern,
    ]
}

private struct ConsumerRunReport: Codable {
    let firstAttemptOutputBitPatterns: [UInt32]
    let forcedFailureError: String
    let forcedFailureTimedOut: Bool
    let forcedFailurePartialOutputElementCount: Int
    let forcedFailureCleanupFailureCount: Int
    let thirdAttemptOutputBitPatterns: [UInt32]
    let executionPathIsolated: Bool
    let cleanEnvironmentObserved: Bool
}

private struct ForcedFailureResult {
    let errorCode: String
    let timedOut: Bool
    let partialOutputCount: Int
    let cleanupFailureCount: Int
}

private enum ConsumerError: Error, CustomStringConvertible {
    case missingArgument(String)
    case repeatedArgument(String)
    case missingBinding(String)
    case dirtyEnvironment([String])
    case unexpectedOutput([UInt32])
    case stallUnexpectedlyReturned
    case unexpectedForcedFailure(String)
    case compilerOrPythonAvailable([String])

    var description: String {
        switch self {
        case .missingArgument(let option):
            "missing argument \(option)"
        case .repeatedArgument(let option):
            "repeated argument \(option)"
        case .missingBinding(let name):
            "missing binding \(name)"
        case .dirtyEnvironment(let names):
            "forbidden execution environment variables: \(names)"
        case .unexpectedOutput(let values):
            "unexpected output bit patterns: \(values)"
        case .stallUnexpectedlyReturned:
            "stall operation unexpectedly returned"
        case .unexpectedForcedFailure(let detail):
            "unexpected forced-failure result: \(detail)"
        case .compilerOrPythonAvailable(let names):
            "compiler or Python remained reachable through PATH: \(names)"
        }
    }
}
