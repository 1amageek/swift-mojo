import Foundation
import MojoPOSIXSupport
import MojoRuntime
import MojoRuntimeProtocolCore
import MojoRuntimeWorker
import Testing

@Suite("Mojo runtime worker startup reader")
struct MojoRuntimeWorkerStartupReaderTests {
    @Test(.timeLimit(.minutes(1)))
    func admitsAFragmentedReadyAndDrainsBoundedDiagnostics() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
        )
        let frameData = try MojoRuntimeWorkerTestFixture.readyFrameData(
            for: verification
        )
        let process = try spawnFrame(
            frameData,
            splitAt: 17,
            diagnostic: "startup-diagnostic"
        )
        defer { cleanup(process) }

        let result = try MojoRuntimeWorkerStartupReader.readReady(
            from: process,
            verification: verification,
            timeout: .seconds(3)
        )

        #expect(!result.sequence.isTerminal)
        #expect(
            String(decoding: result.diagnostics, as: UTF8.self)
                .contains("startup-diagnostic")
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsTruncatedAndOversizedStartupWithoutUnboundedAllocation() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle"),
            maximumFramePayloadBytes: 4_096
        )
        let frameData = try MojoRuntimeWorkerTestFixture.readyFrameData(
            for: verification
        )
        let truncated = try spawnFrame(
            Data(frameData.prefix(10)),
            remainAlive: false
        )
        defer { cleanup(truncated) }

        #expect(
            throws: MojoRuntimeWorkerError.startupEOF(
                expected: MojoRuntimeProtocol.headerByteCount,
                actual: 10
            )
        ) {
            try MojoRuntimeWorkerStartupReader.readReady(
                from: truncated,
                verification: verification,
                timeout: .seconds(3)
            )
        }

        let oversizedHeader = try MojoRuntimeFrameHeader(
            kind: .ready,
            requestID: 0,
            payloadByteCount: verification.maximumFramePayloadBytes + 1
        ).encodedData()
        let oversized = try spawnFrame(
            oversizedHeader,
            remainAlive: false
        )
        defer { cleanup(oversized) }

        #expect(throws: MojoRuntimeWorkerError.startupProtocolFailed) {
            try MojoRuntimeWorkerStartupReader.readReady(
                from: oversized,
                verification: verification,
                timeout: .seconds(3)
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsReadyIdentityDriftAndStartupFailure() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
        )
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes:
                verification.maximumFramePayloadBytes
        )
        let mismatchedReady = try MojoRuntimeWorkerTestFixture.ready(
            for: verification,
            bindingTableDigest: MojoRuntimeWorkerTestFixture.digest("0")
        )
        let mismatchFrame = try MojoRuntimeFrame(
            requestID: 0,
            payload: .ready(mismatchedReady),
            limits: limits
        ).encodedData(limits: limits)
        let mismatchProcess = try spawnFrame(mismatchFrame)
        defer { cleanup(mismatchProcess) }

        #expect(
            throws: MojoRuntimeWorkerError.readyMismatch(
                field: "bindingTableDigest"
            )
        ) {
            try MojoRuntimeWorkerStartupReader.readReady(
                from: mismatchProcess,
                verification: verification,
                timeout: .seconds(3)
            )
        }

        let failureFrame = try MojoRuntimeFrame(
            requestID: 0,
            payload: .failure(
                try MojoRuntimeFailurePayload(
                    code: .internalFailure,
                    diagnostic: "fixture-failure"
                )
            ),
            limits: limits
        ).encodedData(limits: limits)
        let failureProcess = try spawnFrame(failureFrame)
        defer { cleanup(failureProcess) }

        #expect(
            throws: MojoRuntimeWorkerError.startupFailure(
                code: .internalFailure,
                diagnostic: "fixture-failure"
            )
        ) {
            try MojoRuntimeWorkerStartupReader.readReady(
                from: failureProcess,
                verification: verification,
                timeout: .seconds(3)
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func continuousDiagnosticsCannotBypassTheStartupDeadline() throws {
        let verification = MojoRuntimeWorkerTestFixture.verification(
            bundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
        )
        let process = try MojoPOSIXWorkerSupport.spawn(
            executablePath: "/bin/sh",
            arguments: [
                "-c",
                "while :; do printf x >&2; done",
            ]
        )
        defer { cleanup(process) }
        let clock = ContinuousClock()
        let startedAt = clock.now

        #expect(throws: MojoRuntimeWorkerError.startupTimedOut) {
            try MojoRuntimeWorkerStartupReader.readReady(
                from: process,
                verification: verification,
                timeout: .milliseconds(100)
            )
        }
        #expect(startedAt.duration(to: clock.now) < .seconds(2))
    }

    private func spawnFrame(
        _ data: Data,
        splitAt: Int? = nil,
        diagnostic: String? = nil,
        remainAlive: Bool = true
    ) throws -> MojoPOSIXWorkerProcess {
        let split = min(max(splitAt ?? data.count, 0), data.count)
        let first = MojoRuntimeWorkerTestFixture.shellOctal(
            Data(data.prefix(split))
        )
        let second = MojoRuntimeWorkerTestFixture.shellOctal(
            Data(data.dropFirst(split))
        )
        var commands = ["printf '\(first)' >&3"]
        if let diagnostic {
            commands.append("printf '\(diagnostic)' >&2")
        }
        if !second.isEmpty {
            commands.append("sleep 0.05")
            commands.append("printf '\(second)' >&3")
        }
        if remainAlive {
            commands.append("sleep 30")
        }
        return try MojoPOSIXWorkerSupport.spawn(
            executablePath: "/bin/sh",
            arguments: ["-c", commands.joined(separator: "; ")]
        )
    }

    private func cleanup(_ process: MojoPOSIXWorkerProcess) {
        var reaped = false
        do {
            reaped = try MojoPOSIXSupport.waitNoHang(
                processID: process.processID
            ) != nil
        } catch let error as MojoPOSIXSupportError {
            if error == .childAlreadyReaped {
                reaped = true
            } else {
                Issue.record("Failed to inspect startup fixture: \(error)")
            }
        } catch {
            Issue.record("Failed to inspect startup fixture: \(error)")
        }
        if !reaped {
            var signalFailure: Error?
            do {
                try MojoPOSIXSupport.signalProcessGroup(
                    processID: process.processID,
                    signal: MojoPOSIXSupport.killSignal
                )
            } catch {
                signalFailure = error
            }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                do {
                    if try MojoPOSIXSupport.waitNoHang(
                        processID: process.processID
                    ) != nil {
                        reaped = true
                        break
                    }
                } catch {
                    Issue.record("Failed to reap startup fixture: \(error)")
                    break
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
            if !reaped, let signalFailure {
                Issue.record("Failed to kill startup fixture: \(signalFailure)")
            }
        }
        for descriptor in [
            process.protocolDescriptor,
            process.diagnosticDescriptor,
        ] {
            do {
                try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
            } catch {
                Issue.record("Failed to close startup fixture: \(error)")
            }
        }
    }
}
