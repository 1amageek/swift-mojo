import Foundation
import Testing
@testable import RuntimeWorkerAcceptance

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Runtime worker acceptance cleanup")
struct RuntimeWorkerAcceptanceCleanupTests {
    @Test(.timeLimit(.minutes(1)))
    func cleanupKillsWorkerGroupAndRemovesNewStage() async throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "runtime-worker-acceptance-cleanup-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )

        let baselineName = "swift-mojo-worker-baseline"
        let baselineURL = root.appendingPathComponent(
            baselineName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: baselineURL,
            withIntermediateDirectories: false
        )

        let stageName = "swift-mojo-worker-\(UUID().uuidString)"
        let stageURL = root.appendingPathComponent(stageName, isDirectory: true)
        try fileManager.createDirectory(
            at: stageURL,
            withIntermediateDirectories: false
        )
        let sleeperURL = stageURL.appendingPathComponent("sleeper.sh")
        let sleeper = "#!/bin/sh\nwhile :; do\n  /bin/sleep 1\ndone\n"
        try Data(sleeper.utf8).write(to: sleeperURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sleeperURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            "-MPOSIX",
            "-e",
            "POSIX::setsid() or die $!; exec '/bin/sh', $ARGV[0] or die $!;",
            sleeperURL.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        var processGroupID: Int32?
        do {
            try process.run()
            processGroupID = try await Self.waitForProcess(
                processID: process.processIdentifier
            )
            #expect(processGroupID == process.processIdentifier)

            try await RuntimeWorkerAcceptanceController
                .cleanupAbortedConsumer(
                    in: root,
                    baselineStageEntries: [baselineName],
                    primaryDescription: "acceptance cleanup test timeout"
                )

            #expect(!process.isRunning)
            #expect(!fileManager.fileExists(atPath: stageURL.path))
            #expect(fileManager.fileExists(atPath: baselineURL.path))
        } catch {
            if process.isRunning {
                if let processGroupID {
                    _ = kill(-processGroupID, SIGKILL)
                } else {
                    process.terminate()
                }
                _ = await Self.waitForProcessExit(process)
            }
            do {
                try fileManager.removeItem(at: root)
            } catch {
                // Preserve the primary test failure when fixture cleanup fails.
            }
            throw error
        }

        do {
            try fileManager.removeItem(at: root)
        } catch {
            throw RuntimeWorkerAcceptanceCleanupTestError.fixtureRemovalFailed(
                String(describing: error)
            )
        }
        #else
        throw RuntimeWorkerAcceptanceCleanupTestError.unsupportedPlatform
        #endif
    }

    #if canImport(Darwin) || canImport(Glibc)
    private static func waitForProcess(
        processID: Int32
    ) async throws -> Int32 {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            let processGroupID = getpgid(processID)
            if processGroupID == processID {
                return processGroupID
            }
            if processGroupID < 0, errno != ESRCH {
                throw RuntimeWorkerAcceptanceCleanupTestError
                    .processInspectionFailed(
                        "getpgid failed with errno \(errno)"
                    )
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                throw RuntimeWorkerAcceptanceCleanupTestError
                    .processVisibilityInterrupted
            }
        }
        throw RuntimeWorkerAcceptanceCleanupTestError
            .processVisibilityTimedOut
    }

    private static func waitForProcessExit(_ process: Process) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while process.isRunning && clock.now < deadline {
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                await Task.yield()
            }
        }
        return !process.isRunning
    }
    #endif
}

private enum RuntimeWorkerAcceptanceCleanupTestError: Error {
    case fixtureRemovalFailed(String)
    case processInspectionFailed(String)
    case processVisibilityInterrupted
    case processVisibilityTimedOut
    case unsupportedPlatform
}
