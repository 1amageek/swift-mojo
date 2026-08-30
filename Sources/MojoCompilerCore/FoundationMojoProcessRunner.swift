import Foundation
import MojoPOSIXSupport

package struct FoundationMojoProcessRunner: MojoProcessRunning {
    private enum WaitOutcome {
        case exited(Int32)
        case timedOut
    }

    private let environment: [String: String]?
    private let pollInterval: TimeInterval
    private let terminationGraceSeconds: Int
    private let timeoutSeconds: Int

    package init(
        environment: [String: String]? = nil,
        timeoutSeconds: Int = 300,
        terminationGraceSeconds: Int = 2,
        pollInterval: TimeInterval = 0.02
    ) {
        precondition(timeoutSeconds > 0)
        precondition(terminationGraceSeconds > 0)
        precondition(pollInterval > 0)
        self.environment = environment
        self.timeoutSeconds = timeoutSeconds
        self.terminationGraceSeconds = terminationGraceSeconds
        self.pollInterval = pollInterval
    }

    package func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        let command = ([executablePath] + arguments).joined(separator: " ")
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swift-mojo-process-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        do {
            let result = try capture(
                executablePath: executablePath,
                arguments: arguments,
                command: command,
                temporaryDirectory: temporaryDirectory
            )
            try FileManager.default.removeItem(at: temporaryDirectory)
            return result
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: temporaryDirectory.path) {
                    try FileManager.default.removeItem(at: temporaryDirectory)
                }
            } catch let cleanupError {
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
    }

    private func capture(
        executablePath: String,
        arguments: [String],
        command: String,
        temporaryDirectory: URL
    ) throws -> MojoProcessResult {
        let outputURL = temporaryDirectory.appendingPathComponent("output.log")
        let outputDescriptor: Int32
        do {
            outputDescriptor = try MojoPOSIXSupport.openOutputFile(
                path: outputURL.path
            )
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: String(describing: error)
            )
        }
        let result: MojoProcessResult
        do {
            result = try capture(
                executablePath: executablePath,
                arguments: arguments,
                outputDescriptor: outputDescriptor,
                command: command
            )
        } catch {
            let primaryError = error
            do {
                try MojoPOSIXSupport.closeFile(outputDescriptor)
            } catch let cleanupError {
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: "Primary error: \(primaryError); descriptor cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
        do {
            try MojoPOSIXSupport.closeFile(outputDescriptor)
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "Descriptor cleanup failed: \(error)"
            )
        }
        return result
    }

    private func capture(
        executablePath: String,
        arguments: [String],
        outputDescriptor: Int32,
        command: String
    ) throws -> MojoProcessResult {
        let processID = try spawn(
            executablePath: executablePath,
            arguments: arguments,
            outputDescriptor: outputDescriptor,
            command: command
        )
        let outcome: WaitOutcome
        do {
            outcome = try waitForExit(processID: processID, command: command)
        } catch {
            let primaryError = error
            do {
                try terminateAndReap(processID: processID, command: command)
            } catch let cleanupError {
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: "Primary error: \(primaryError); process cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
        switch outcome {
        case .exited:
            try terminateRemainingProcessGroup(
                processID: processID,
                command: command
            )
        case .timedOut:
            try terminateAndReap(processID: processID, command: command)
        }
        let data: Data
        do {
            try MojoPOSIXSupport.seekToStart(outputDescriptor)
            data = try MojoPOSIXSupport.readOutput(outputDescriptor)
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: String(describing: error)
            )
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw MojoCompilerToolError.compilerOutputWasNotUTF8(
                command: command
            )
        }

        switch outcome {
        case .exited(let status):
            return MojoProcessResult(status: status, output: output)
        case .timedOut:
            throw MojoCompilerToolError.processTimedOut(
                command: command,
                seconds: timeoutSeconds,
                diagnostic: output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    private func spawn(
        executablePath: String,
        arguments: [String],
        outputDescriptor: Int32,
        command: String
    ) throws -> MojoPOSIXSupport.ProcessID {
        do {
            return try MojoPOSIXSupport.spawn(
                executablePath: executablePath,
                arguments: arguments,
                environment: environment,
                outputDescriptor: outputDescriptor
            )
        } catch let error as MojoPOSIXSupportError {
            switch error {
            case .processLaunchFailed(let diagnostic):
                throw MojoCompilerToolError.processLaunchFailed(
                    command: command,
                    message: diagnostic
                )
            case .unsupportedPlatform,
                 .operationFailed,
                 .childAlreadyReaped:
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: error.description
                )
            }
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: String(describing: error)
            )
        }
    }

    private func waitForExit(
        processID: MojoPOSIXSupport.ProcessID,
        command: String
    ) throws -> WaitOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            if let status = try pollForExit(
                processID: processID,
                command: command
            ) {
                return .exited(Self.exitStatus(from: status))
            }
            sleepUntilNextPoll(clock: clock, deadline: deadline)
        }
        if let status = try pollForExit(
            processID: processID,
            command: command
        ) {
            return .exited(Self.exitStatus(from: status))
        }
        return .timedOut
    }

    private func terminateAndReap(
        processID: MojoPOSIXSupport.ProcessID,
        command: String
    ) throws {
        try Self.signalProcessGroup(
            processID: processID,
            signal: MojoPOSIXSupport.terminationSignal,
            command: command
        )
        if try waitForReap(
            processID: processID,
            duration: .seconds(terminationGraceSeconds),
            command: command
        ) {
            try terminateRemainingProcessGroup(
                processID: processID,
                command: command
            )
            return
        }

        try Self.signalProcessGroup(
            processID: processID,
            signal: MojoPOSIXSupport.killSignal,
            command: command
        )
        guard try waitForReap(
            processID: processID,
            duration: .seconds(terminationGraceSeconds),
            command: command
        ) else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "Process group \(processID) did not exit after SIGKILL"
            )
        }
        try terminateRemainingProcessGroup(
            processID: processID,
            command: command
        )
    }

    private func terminateRemainingProcessGroup(
        processID: MojoPOSIXSupport.ProcessID,
        command: String
    ) throws {
        guard Self.processGroupIsAlive(processID) else { return }
        try Self.signalProcessGroup(
            processID: processID,
            signal: MojoPOSIXSupport.terminationSignal,
            command: command
        )
        if waitForProcessGroupExit(processID: processID) { return }
        try Self.signalProcessGroup(
            processID: processID,
            signal: MojoPOSIXSupport.killSignal,
            command: command
        )
        guard waitForProcessGroupExit(processID: processID) else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "Process group \(processID) remained alive after SIGKILL"
            )
        }
    }

    private func waitForProcessGroupExit(
        processID: MojoPOSIXSupport.ProcessID
    ) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .seconds(terminationGraceSeconds)
        )
        while clock.now < deadline {
            guard Self.processGroupIsAlive(processID) else { return true }
            sleepUntilNextPoll(clock: clock, deadline: deadline)
        }
        return !Self.processGroupIsAlive(processID)
    }

    private func waitForReap(
        processID: MojoPOSIXSupport.ProcessID,
        duration: Duration,
        command: String
    ) throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if try pollForExit(processID: processID, command: command) != nil {
                return true
            }
            sleepUntilNextPoll(clock: clock, deadline: deadline)
        }
        return try pollForExit(processID: processID, command: command) != nil
    }

    private func sleepUntilNextPoll(
        clock: ContinuousClock,
        deadline: ContinuousClock.Instant
    ) {
        let remaining = clock.now.duration(to: deadline)
        let sleepSeconds = min(
            pollInterval,
            max(0, Self.timeInterval(from: remaining))
        )
        if sleepSeconds > 0 {
            Thread.sleep(forTimeInterval: sleepSeconds)
        }
    }

    private func pollForExit(
        processID: MojoPOSIXSupport.ProcessID,
        command: String
    ) throws -> Int32? {
        do {
            return try MojoPOSIXSupport.waitNoHang(processID: processID)
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: String(describing: error)
            )
        }
    }

    private static func signalProcessGroup(
        processID: MojoPOSIXSupport.ProcessID,
        signal: Int32,
        command: String
    ) throws {
        do {
            try MojoPOSIXSupport.signalProcessGroup(
                processID: processID,
                signal: signal
            )
        } catch {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: String(describing: error)
            )
        }
    }

    private static func processGroupIsAlive(
        _ processID: MojoPOSIXSupport.ProcessID
    ) -> Bool {
        MojoPOSIXSupport.processGroupIsAlive(processID)
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        MojoPOSIXSupport.exitStatus(from: waitStatus)
    }

    private static func timeInterval(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
