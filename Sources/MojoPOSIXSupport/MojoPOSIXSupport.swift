import CMojoPOSIXSupport
import Foundation

package enum MojoPOSIXSupportError: Error, Equatable, CustomStringConvertible {
    case unsupportedPlatform(operation: String)
    case operationFailed(operation: String, diagnostic: String)
    case processLaunchFailed(diagnostic: String)
    case childAlreadyReaped

    package var description: String {
        switch self {
        case .unsupportedPlatform(let operation):
            "POSIX operation '\(operation)' is unsupported on this platform"
        case .operationFailed(let operation, let diagnostic):
            "\(operation) failed: \(diagnostic)"
        case .processLaunchFailed(let diagnostic):
            "Process launch failed: \(diagnostic)"
        case .childAlreadyReaped:
            "The child process was reaped outside its owner"
        }
    }
}

package enum MojoPOSIXSupport {
    package typealias ProcessID = Int32

    package static var isSupported: Bool {
        swift_mojo_posix_platform_supported() == 1
    }

    package static var terminationSignal: Int32 {
        swift_mojo_posix_termination_signal()
    }

    package static var killSignal: Int32 {
        swift_mojo_posix_kill_signal()
    }

    package static func openOutputFile(path: String) throws -> Int32 {
        try openFile(path: path, truncate: true)
    }

    package static func openLockFile(path: String) throws -> Int32 {
        try openFile(path: path, truncate: false)
    }

    package static func closeFile(_ descriptor: Int32) throws {
        try requireSupported(operation: "close file descriptor")
        var errorCode: Int32 = 0
        guard swift_mojo_posix_close_file(descriptor, &errorCode) == 0 else {
            throw failure(operation: "close file descriptor", code: errorCode)
        }
    }

    package static func lockExclusive(_ descriptor: Int32) throws {
        try requireSupported(operation: "acquire output lock")
        var errorCode: Int32 = 0
        guard swift_mojo_posix_lock_exclusive(descriptor, &errorCode) == 0 else {
            throw failure(operation: "acquire output lock", code: errorCode)
        }
    }

    package static func tryLockExclusive(_ descriptor: Int32) throws -> Bool {
        try requireSupported(operation: "try output lock")
        var errorCode: Int32 = 0
        let result = swift_mojo_posix_try_lock_exclusive(
            descriptor,
            &errorCode
        )
        if result == 1 { return true }
        if result == 0 { return false }
        throw failure(operation: "try output lock", code: errorCode)
    }

    package static func unlock(_ descriptor: Int32) throws {
        try requireSupported(operation: "release output lock")
        var errorCode: Int32 = 0
        guard swift_mojo_posix_unlock(descriptor, &errorCode) == 0 else {
            throw failure(operation: "release output lock", code: errorCode)
        }
    }

    package static func spawn(
        executablePath: String,
        arguments: [String],
        environment: [String: String]?,
        outputDescriptor: Int32
    ) throws -> ProcessID {
        try requireSupported(operation: "spawn process")
        let argumentStorage = MojoPOSIXCStringArray(
            [executablePath] + arguments
        )
        let environmentStorage = environment.map { values in
            MojoPOSIXCStringArray(
                values.keys.sorted().map { key in
                    "\(key)=\(values[key] ?? "")"
                }
            )
        }
        var processID: Int32 = 0
        var errorCode: Int32 = 0
        let result = executablePath.withCString { executable in
            argumentStorage.withUnsafeMutablePointers { argumentPointers in
                if let environmentStorage {
                    return environmentStorage.withUnsafeMutablePointers {
                        environmentPointers in
                        swift_mojo_posix_spawn(
                            executable,
                            argumentPointers,
                            environmentPointers,
                            outputDescriptor,
                            &processID,
                            &errorCode
                        )
                    }
                }
                return swift_mojo_posix_spawn(
                    executable,
                    argumentPointers,
                    nil,
                    outputDescriptor,
                    &processID,
                    &errorCode
                )
            }
        }
        guard result == SWIFT_MOJO_POSIX_SPAWN_SUCCEEDED else {
            let diagnostic = errorDescription(code: errorCode)
            if result == SWIFT_MOJO_POSIX_SPAWN_LAUNCH_FAILED {
                throw MojoPOSIXSupportError.processLaunchFailed(
                    diagnostic: diagnostic
                )
            }
            throw failure(operation: "spawn process", code: errorCode)
        }
        return processID
    }

    package static func waitNoHang(
        processID: ProcessID
    ) throws -> Int32? {
        try requireSupported(operation: "wait for process")
        var waitStatus: Int32 = 0
        var errorCode: Int32 = 0
        let result = swift_mojo_posix_wait_nohang(
            processID,
            &waitStatus,
            &errorCode
        )
        if result == 1 { return waitStatus }
        if result == 0 { return nil }
        if swift_mojo_posix_error_is_no_child(errorCode) == 1 {
            throw MojoPOSIXSupportError.childAlreadyReaped
        }
        throw failure(operation: "wait for process", code: errorCode)
    }

    package static func signalProcessGroup(
        processID: ProcessID,
        signal: Int32
    ) throws {
        try requireSupported(operation: "signal process group")
        var errorCode: Int32 = 0
        guard swift_mojo_posix_signal_group(
            processID,
            signal,
            &errorCode
        ) == 0 else {
            throw failure(operation: "signal process group", code: errorCode)
        }
    }

    package static func processGroupIsAlive(_ processID: ProcessID) -> Bool {
        swift_mojo_posix_process_group_alive(processID) == 1
    }

    package static func processIsAlive(_ processID: ProcessID) -> Bool {
        swift_mojo_posix_process_alive(processID) == 1
    }

    package static func seekToStart(_ descriptor: Int32) throws {
        try requireSupported(operation: "seek process output")
        var errorCode: Int32 = 0
        guard swift_mojo_posix_seek_start(descriptor, &errorCode) >= 0 else {
            throw failure(operation: "seek process output", code: errorCode)
        }
    }

    package static func readOutput(_ descriptor: Int32) throws -> Data {
        try requireSupported(operation: "read process output")
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            var errorCode: Int32 = 0
            let count = buffer.withUnsafeMutableBytes { bytes in
                swift_mojo_posix_read(
                    descriptor,
                    bytes.baseAddress,
                    Int64(bytes.count),
                    &errorCode
                )
            }
            if count > 0 {
                data.append(buffer, count: Int(count))
                continue
            }
            if count == 0 { return data }
            throw failure(operation: "read process output", code: errorCode)
        }
    }

    package static func exit(_ status: Int32) -> Never {
        swift_mojo_posix_exit(status)
        fatalError("POSIX exit unexpectedly returned")
    }

    package static func exitStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        if signal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + signal
    }

    private static func openFile(
        path: String,
        truncate: Bool
    ) throws -> Int32 {
        try requireSupported(operation: "open file")
        var errorCode: Int32 = 0
        let descriptor = path.withCString { pointer in
            swift_mojo_posix_open_file(
                pointer,
                truncate ? 1 : 0,
                &errorCode
            )
        }
        guard descriptor >= 0 else {
            throw failure(operation: "open '\(path)'", code: errorCode)
        }
        return descriptor
    }

    private static func requireSupported(operation: String) throws {
        guard isSupported else {
            throw MojoPOSIXSupportError.unsupportedPlatform(
                operation: operation
            )
        }
    }

    private static func failure(
        operation: String,
        code: Int32
    ) -> MojoPOSIXSupportError {
        .operationFailed(
            operation: operation,
            diagnostic: errorDescription(code: code)
        )
    }

    private static func errorDescription(code: Int32) -> String {
        String(cString: swift_mojo_posix_error_description(code))
    }
}

private final class MojoPOSIXCStringArray {
    private var pointers: [UnsafeMutablePointer<CChar>?]

    init(_ strings: [String]) {
        pointers = strings.map { string in
            let bytes = string.utf8CString
            let pointer = UnsafeMutablePointer<CChar>.allocate(
                capacity: bytes.count
            )
            bytes.withUnsafeBufferPointer { buffer in
                pointer.initialize(
                    from: buffer.baseAddress!,
                    count: buffer.count
                )
            }
            return pointer
        }
        pointers.append(nil)
    }

    deinit {
        for pointer in pointers {
            pointer?.deallocate()
        }
    }

    func withUnsafeMutablePointers<Result>(
        _ body: (
            UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        ) -> Result
    ) -> Result {
        pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
