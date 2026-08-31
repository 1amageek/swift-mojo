import Foundation
@testable import RuntimeWorkerAcceptance
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Runtime worker acceptance bounded process handling")
struct RuntimeWorkerAcceptanceTimeoutTests {
    @Test(.timeLimit(.minutes(1)))
    func dualPipesDrainBeyondCapacityWithoutDeadlock() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let result = try await RuntimeWorkerAcceptanceController
            .runConsumerForTesting(
                configuration: fixture.configuration(
                    executable: fixture.dualOutputExecutable,
                    deadline: .seconds(5)
                ),
                emptyExecutionPath: fixture.emptyExecutionPath
            )

        #expect(result.status == 0)
        #expect(result.stdout == Data(repeating: 111, count: 256 * 1024))
        #expect(result.stderr == Data(repeating: 101, count: 256 * 1024))
        #expect(try fixture.captureFiles().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func consumerTimeoutForceKillsWithinOneHardDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let started = ContinuousClock().now
        do {
            _ = try await RuntimeWorkerAcceptanceController
                .runConsumerForTesting(
                    configuration: fixture.configuration(
                        executable: fixture.timeoutExecutable,
                        deadline: .seconds(2)
                    ),
                    emptyExecutionPath: fixture.emptyExecutionPath
                )
            Issue.record("the uncooperative consumer unexpectedly exited")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            #expect(error == .consumerTimedOut)
        }
        #expect(
            ContinuousClock().now - started < .seconds(3),
            "consumer stop exceeded its one fixed hard deadline"
        )
        try await fixture.requireProcessGone(at: fixture.timeoutProcessIDURL)
        #expect(try fixture.captureFiles().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func outputOverFourMiBIsRejectedWithoutStoringTheExtraByte() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        do {
            _ = try await RuntimeWorkerAcceptanceController
                .runConsumerForTesting(
                    configuration: fixture.configuration(
                        executable: fixture.overflowExecutable,
                        deadline: .seconds(5)
                    ),
                    emptyExecutionPath: fixture.emptyExecutionPath
                )
            Issue.record("oversized consumer output unexpectedly succeeded")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            guard case .consumerOutputFailed(let detail) = error else {
                Issue.record("unexpected oversized-output error: \(error)")
                return
            }
            #expect(detail.contains("stdout exceeded 4194304 bytes"))
        }
        try await fixture.requireProcessGone(at: fixture.overflowProcessIDURL)
        #expect(try fixture.captureFiles().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func inheritedWriterPreventsFalseSuccessUntilHardDeadline() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        do {
            _ = try await RuntimeWorkerAcceptanceController
                .runConsumerForTesting(
                    configuration: fixture.configuration(
                        executable: fixture.inheritedWriterExecutable,
                        deadline: .seconds(1)
                    ),
                    emptyExecutionPath: fixture.emptyExecutionPath
                )
            Issue.record("missing pipe EOF was incorrectly accepted")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            #expect(error == .consumerTimedOut)
        }
        try await fixture.requireProcessGone(
            at: fixture.inheritedWriterProcessIDURL
        )
        #expect(try fixture.captureFiles().isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func processInspectionTimeoutIsTypedAndLeavesNoCaptureResource()
        async throws
    {
        let fixture = try Fixture()
        defer { fixture.remove() }

        do {
            _ = try await RuntimeWorkerAcceptanceController
                .inspectWorkerProcessLinesForTesting(
                    in: fixture.root,
                    executableURL: fixture.timeoutExecutable
                )
            Issue.record("uncooperative process inspection unexpectedly exited")
        } catch let error as RuntimeWorkerAcceptanceRunnerError {
            guard case .processInspectionFailed(let detail) = error else {
                Issue.record("unexpected process inspection error: \(error)")
                return
            }
            #expect(detail.contains("bounded deadline"))
        }
        try await fixture.requireProcessGone(at: fixture.timeoutProcessIDURL)
        #expect(try fixture.captureFiles().isEmpty)
    }
}

private final class Fixture {
    let fileManager = FileManager.default
    let root: URL
    let emptyExecutionPath: URL
    let dualOutputExecutable: URL
    let timeoutExecutable: URL
    let overflowExecutable: URL
    let inheritedWriterExecutable: URL
    let timeoutProcessIDURL: URL
    let overflowProcessIDURL: URL
    let inheritedWriterProcessIDURL: URL

    init() throws {
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "runtime-worker-acceptance-timeout-\(UUID().uuidString)",
            isDirectory: true
        )
        emptyExecutionPath = root.appendingPathComponent(
            "empty-bin",
            isDirectory: true
        )
        dualOutputExecutable = root.appendingPathComponent("dual-output.pl")
        timeoutExecutable = root.appendingPathComponent("timeout.pl")
        overflowExecutable = root.appendingPathComponent("overflow.pl")
        inheritedWriterExecutable = root.appendingPathComponent(
            "inherited-writer.pl"
        )
        timeoutProcessIDURL = root.appendingPathComponent("timeout.pid")
        overflowProcessIDURL = root.appendingPathComponent("overflow.pid")
        inheritedWriterProcessIDURL = root.appendingPathComponent(
            "inherited-writer.pid"
        )

        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: emptyExecutionPath,
            withIntermediateDirectories: false
        )
        try writeExecutable(
            at: dualOutputExecutable,
            source: """
            #!/usr/bin/perl
            print STDOUT 'o' x (256 * 1024);
            print STDERR 'e' x (256 * 1024);
            """
        )
        try writeExecutable(
            at: timeoutExecutable,
            source: """
            #!/usr/bin/perl
            open(my $pid, '>', '\(timeoutProcessIDURL.path)') or die $!;
            print $pid $$;
            close($pid);
            $SIG{'TERM'} = 'IGNORE';
            while (1) { select(undef, undef, undef, 0.01); }
            """
        )
        try writeExecutable(
            at: overflowExecutable,
            source: """
            #!/usr/bin/perl
            open(my $pid, '>', '\(overflowProcessIDURL.path)') or die $!;
            print $pid $$;
            close($pid);
            $SIG{'TERM'} = 'IGNORE';
            for (1 .. 65) { print STDOUT 'x' x (64 * 1024); }
            while (1) { select(undef, undef, undef, 0.01); }
            """
        )
        try writeExecutable(
            at: inheritedWriterExecutable,
            source: """
            #!/usr/bin/perl
            pipe(my $ready_reader, my $ready_writer) or die $!;
            my $child = fork();
            die $! unless defined $child;
            if ($child == 0) {
                close($ready_reader);
                open(my $pid, '>', '\(inheritedWriterProcessIDURL.path)') or die $!;
                print $pid $$;
                close($pid);
                print $ready_writer '1';
                close($ready_writer);
                $SIG{'TERM'} = 'IGNORE';
                select(undef, undef, undef, 1.5);
                exit 0;
            }
            close($ready_writer);
            my $ready = '';
            my $read_count = sysread($ready_reader, $ready, 1);
            die $! unless defined $read_count;
            die 'child did not publish readiness' unless $read_count == 1;
            close($ready_reader);
            print STDOUT 'parent';
            exit 0;
            """
        )
    }

    func configuration(
        executable: URL,
        deadline: Duration
    ) throws -> RuntimeWorkerAcceptanceRunConfiguration {
        try RuntimeWorkerAcceptanceRunConfiguration(
            bundleURL: root.appendingPathComponent("bundle", isDirectory: true),
            consumerExecutableURL: executable,
            temporaryDirectoryURL: root,
            repositoryRootURL: root,
            expectedSourceDigest: String(repeating: "0", count: 64),
            swiftMojoRevision: String(repeating: "0", count: 40),
            consumerDeadline: deadline
        )
    }

    func captureFiles() throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        )
        .filter { $0.lastPathComponent.hasPrefix(".runtime-worker-") }
    }

    func requireProcessGone(at processIDURL: URL) async throws {
        let processIDText = try String(
            contentsOf: processIDURL,
            encoding: .utf8
        )
        let processID = try #require(Int32(processIDText))
        let deadline = ContinuousClock().now.advanced(by: .seconds(1))
        while Self.processExists(processID), ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!Self.processExists(processID))
    }

    func remove() {
        do {
            try fileManager.removeItem(at: root)
        } catch {
            Issue.record("timeout fixture cleanup failed: \(error)")
        }
    }

    private func writeExecutable(at url: URL, source: String) throws {
        try Data(source.utf8).write(to: url)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private static func processExists(_ processID: Int32) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        if kill(processID, 0) == 0 { return true }
        return errno != ESRCH
        #else
        return false
        #endif
    }
}
