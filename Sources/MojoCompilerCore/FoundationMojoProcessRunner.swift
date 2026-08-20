import Darwin
import Foundation

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
        // The filesystem representation is borrowed only for open(2). The
        // returned descriptor owns the file description and is closed exactly once.
        let outputDescriptor = outputURL.path.withCString { path in
            Darwin.open(
                path,
                O_CREAT | O_TRUNC | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard outputDescriptor >= 0 else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: Self.systemErrorDescription()
            )
        }
        defer { _ = Darwin.close(outputDescriptor) }

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
        let data = try Self.readOutput(
            descriptor: outputDescriptor,
            command: command
        )
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
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        try Self.requirePOSIXSuccess(
            posix_spawn_file_actions_init(&actions),
            operation: "posix_spawn_file_actions_init",
            command: command
        )
        defer { posix_spawn_file_actions_destroy(&actions) }

        var attributes: posix_spawnattr_t? = nil
        try Self.requirePOSIXSuccess(
            posix_spawnattr_init(&attributes),
            operation: "posix_spawnattr_init",
            command: command
        )
        defer { posix_spawnattr_destroy(&attributes) }

        try Self.requirePOSIXSuccess(
            posix_spawn_file_actions_adddup2(
                &actions,
                outputDescriptor,
                STDOUT_FILENO
            ),
            operation: "redirect stdout",
            command: command
        )
        try Self.requirePOSIXSuccess(
            posix_spawn_file_actions_adddup2(
                &actions,
                outputDescriptor,
                STDERR_FILENO
            ),
            operation: "redirect stderr",
            command: command
        )
        if outputDescriptor != STDOUT_FILENO,
           outputDescriptor != STDERR_FILENO {
            try Self.requirePOSIXSuccess(
                posix_spawn_file_actions_addclose(&actions, outputDescriptor),
                operation: "close inherited output descriptor",
                command: command
            )
        }
        try Self.requirePOSIXSuccess(
            posix_spawnattr_setflags(
                &attributes,
                Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
            ),
            operation: "configure process session",
            command: command
        )

        let argumentStorage = try MojoProcessCStringArray(
            [executablePath] + arguments,
            command: command
        )
        let environmentStorage = try environment.map { environment in
            try MojoProcessCStringArray(
                environment.keys.sorted().map { key in
                    "\(key)=\(environment[key] ?? "")"
                },
                command: command
            )
        }
        var processID = pid_t()
        let spawnResult = try executablePath.withCString { executable in
            try argumentStorage.withUnsafeMutablePointers { argumentPointers in
                if let environmentStorage {
                    return try environmentStorage.withUnsafeMutablePointers {
                        environmentPointers in
                        posix_spawn(
                            &processID,
                            executable,
                            &actions,
                            &attributes,
                            argumentPointers,
                            environmentPointers
                        )
                    }
                }
                posix_spawn(
                    &processID,
                    executable,
                    &actions,
                    &attributes,
                    argumentPointers,
                    Darwin.environ
                )
            }
        }
        guard spawnResult == 0 else {
            throw MojoCompilerToolError.processLaunchFailed(
                command: command,
                message: String(cString: strerror(spawnResult))
            )
        }
        return processID
    }

    private func waitForExit(
        processID: pid_t,
        command: String
    ) throws -> WaitOutcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            if let status = try pollForExit(
                processID: processID,
                command: command
            ) {
                try terminateRemainingProcessGroup(
                    processID: processID,
                    command: command
                )
                return .exited(Self.exitStatus(from: status))
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        try terminateAndReap(processID: processID, command: command)
        return .timedOut
    }

    private func terminateAndReap(
        processID: pid_t,
        command: String
    ) throws {
        try Self.signalProcessGroup(
            processID: processID,
            signal: SIGTERM,
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
            signal: SIGKILL,
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
        processID: pid_t,
        command: String
    ) throws {
        guard Self.processGroupIsAlive(processID) else { return }
        try Self.signalProcessGroup(
            processID: processID,
            signal: SIGTERM,
            command: command
        )
        if waitForProcessGroupExit(processID: processID) { return }
        try Self.signalProcessGroup(
            processID: processID,
            signal: SIGKILL,
            command: command
        )
        guard waitForProcessGroupExit(processID: processID) else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "Process group \(processID) remained alive after SIGKILL"
            )
        }
    }

    private func waitForProcessGroupExit(processID: pid_t) -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(
            by: .seconds(terminationGraceSeconds)
        )
        while clock.now < deadline {
            guard Self.processGroupIsAlive(processID) else { return true }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return !Self.processGroupIsAlive(processID)
    }

    private func waitForReap(
        processID: pid_t,
        duration: Duration,
        command: String
    ) throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if try pollForExit(processID: processID, command: command) != nil {
                return true
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return try pollForExit(processID: processID, command: command) != nil
    }

    private func pollForExit(
        processID: pid_t,
        command: String
    ) throws -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, WNOHANG)
            if result == processID { return status }
            if result == 0 { return nil }
            if result == -1, errno == EINTR { continue }
            if result == -1, errno == ECHILD {
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: "The child process was reaped outside its owner"
                )
            }
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "waitpid failed: \(Self.systemErrorDescription())"
            )
        }
    }

    private static func signalProcessGroup(
        processID: pid_t,
        signal: Int32,
        command: String
    ) throws {
        guard Darwin.kill(-processID, signal) == 0 || errno == ESRCH else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "Failed to signal process group \(processID): \(systemErrorDescription())"
            )
        }
    }

    private static func processGroupIsAlive(_ processID: pid_t) -> Bool {
        Darwin.kill(-processID, 0) == 0 || errno == EPERM
    }

    private static func exitStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func readOutput(
        descriptor: Int32,
        command: String
    ) throws -> Data {
        guard Darwin.lseek(descriptor, 0, SEEK_SET) >= 0 else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "lseek failed: \(systemErrorDescription())"
            )
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            // The mutable byte view is initialized storage owned by buffer. Its
            // base address is borrowed only for read(2) and does not escape.
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if readCount > 0 {
                data.append(buffer, count: readCount)
                continue
            }
            if readCount == 0 { return data }
            if errno == EINTR { continue }
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "read failed: \(systemErrorDescription())"
            )
        }
    }

    private static func requirePOSIXSuccess(
        _ result: Int32,
        operation: String,
        command: String
    ) throws {
        guard result == 0 else {
            throw MojoCompilerToolError.processControlFailed(
                command: command,
                diagnostic: "\(operation) failed: \(String(cString: strerror(result)))"
            )
        }
    }

    private static func systemErrorDescription() -> String {
        String(cString: strerror(errno))
    }
}

// This owner allocates one NUL-terminated buffer per argument with strdup,
// retains every pointer for the complete posix_spawn call, and frees each
// allocation exactly once. The mutable pointer array never escapes its borrow.
private final class MojoProcessCStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?] = []

    init(_ strings: [String], command: String) throws {
        for string in strings {
            guard let pointer = strdup(string) else {
                for allocatedPointer in pointers {
                    free(allocatedPointer)
                }
                pointers.removeAll(keepingCapacity: false)
                throw MojoCompilerToolError.processControlFailed(
                    command: command,
                    diagnostic: "Unable to allocate process argument storage"
                )
            }
            pointers.append(pointer)
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers {
            free(pointer)
        }
    }

    func withUnsafeMutablePointers<Result>(
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) throws -> Result
    ) throws -> Result {
        // strdup owns every string allocation until this object is released.
        // The argv buffer is borrowed only by posix_spawn and cannot escape.
        try pointers.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw MojoCompilerToolError.processControlFailed(
                    command: "prepare process arguments",
                    diagnostic: "Process argument buffer is unavailable"
                )
            }
            return try body(baseAddress)
        }
    }
}
