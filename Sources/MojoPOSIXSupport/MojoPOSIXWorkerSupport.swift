import CMojoPOSIXSupport
import Foundation

package struct MojoPOSIXWorkerProcess: Sendable {
  package let processID: MojoPOSIXSupport.ProcessID
  package let protocolDescriptor: Int32
  package let diagnosticDescriptor: Int32

  package init(
    processID: MojoPOSIXSupport.ProcessID,
    protocolDescriptor: Int32,
    diagnosticDescriptor: Int32
  ) {
    self.processID = processID
    self.protocolDescriptor = protocolDescriptor
    self.diagnosticDescriptor = diagnosticDescriptor
  }
}

package struct MojoPOSIXWorkerWakeup: Sendable {
  package let readDescriptor: Int32
  package let writeDescriptor: Int32

  package init(readDescriptor: Int32, writeDescriptor: Int32) {
    self.readDescriptor = readDescriptor
    self.writeDescriptor = writeDescriptor
  }
}

package struct MojoPOSIXWorkerPollInterest: OptionSet, Sendable {
  package let rawValue: Int32

  package init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  package static let read = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_INTEREST_READ)
  )
  package static let write = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_INTEREST_WRITE)
  )
}

package struct MojoPOSIXWorkerPollEvents: OptionSet, Sendable {
  package let rawValue: Int32

  package init(rawValue: Int32) {
    self.rawValue = rawValue
  }

  package static let protocolReadable = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_READABLE)
  )
  package static let protocolWritable = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_WRITABLE)
  )
  package static let diagnosticReadable = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_READABLE)
  )
  package static let wakeupReadable = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_READABLE)
  )
  package static let protocolHangup = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_HANGUP)
  )
  package static let diagnosticHangup = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_HANGUP)
  )
  package static let wakeupHangup = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_HANGUP)
  )
  package static let protocolError = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_ERROR)
  )
  package static let diagnosticError = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_ERROR)
  )
  package static let wakeupError = Self(
    rawValue: Int32(SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_ERROR)
  )
}

package enum MojoPOSIXWorkerPollResult: Equatable, Sendable {
  case ready(MojoPOSIXWorkerPollEvents)
  case timedOut
  case interrupted
}

package enum MojoPOSIXWorkerIOResult: Equatable, Sendable {
  case bytes(Int)
  case eof
  case interrupted
  case wouldBlock
}

package struct MojoPOSIXWorkerWakeupDrain: Equatable, Sendable {
  package let consumedBytes: Int
  package let limitReached: Bool

  package init(consumedBytes: Int, limitReached: Bool) {
    self.consumedBytes = consumedBytes
    self.limitReached = limitReached
  }
}

package enum MojoPOSIXWorkerSupportError:
  Error, Equatable, CustomStringConvertible, Sendable
{
  case invalidTimeout
  case invalidBuffer

  package var description: String {
    switch self {
    case .invalidTimeout:
      "Worker I/O timeout must be finite and non-negative"
    case .invalidBuffer:
      "Worker I/O buffer must be non-empty and valid"
    }
  }
}

package enum MojoPOSIXWorkerSupport {
  package static var isSupported: Bool {
    swift_mojo_posix_worker_platform_supported() == 1
  }

  package static func spawn(
    executablePath: String,
    arguments: [String],
    environment: [String: String]? = nil
  ) throws -> MojoPOSIXWorkerProcess {
    try requireSupported(operation: "spawn worker")
    let argumentStorage = MojoPOSIXWorkerCStringArray(
      [executablePath] + arguments
    )
    let environmentStorage = environment.map { values in
      MojoPOSIXWorkerCStringArray(
        values.keys.sorted().map { key in
          "\(key)=\(values[key] ?? "")"
        }
      )
    }
    var protocolDescriptor: Int32 = -1
    var diagnosticDescriptor: Int32 = -1
    var processID: Int32 = 0
    var errorCode: Int32 = 0
    let result = executablePath.withCString { executable in
      argumentStorage.withUnsafeMutablePointers { argumentPointers in
        if let environmentStorage {
          return environmentStorage.withUnsafeMutablePointers {
            environmentPointers in
            swift_mojo_posix_worker_spawn(
              executable,
              argumentPointers,
              environmentPointers,
              &protocolDescriptor,
              &diagnosticDescriptor,
              &processID,
              &errorCode
            )
          }
        }
        return swift_mojo_posix_worker_spawn(
          executable,
          argumentPointers,
          nil,
          &protocolDescriptor,
          &diagnosticDescriptor,
          &processID,
          &errorCode
        )
      }
    }
    guard result == SWIFT_MOJO_POSIX_WORKER_SPAWN_SUCCEEDED else {
      let diagnostic = errorDescription(code: errorCode)
      if result == SWIFT_MOJO_POSIX_WORKER_SPAWN_LAUNCH_FAILED {
        throw MojoPOSIXSupportError.processLaunchFailed(
          diagnostic: diagnostic
        )
      }
      throw MojoPOSIXSupportError.operationFailed(
        operation: "spawn worker",
        diagnostic: diagnostic
      )
    }
    return MojoPOSIXWorkerProcess(
      processID: processID,
      protocolDescriptor: protocolDescriptor,
      diagnosticDescriptor: diagnosticDescriptor
    )
  }

  package static func createWakeup() throws -> MojoPOSIXWorkerWakeup {
    try requireSupported(operation: "create worker wakeup")
    var readDescriptor: Int32 = -1
    var writeDescriptor: Int32 = -1
    var errorCode: Int32 = 0
    guard
      swift_mojo_posix_worker_create_wakeup(
        &readDescriptor,
        &writeDescriptor,
        &errorCode
      ) == 0
    else {
      throw failure(operation: "create worker wakeup", code: errorCode)
    }
    return MojoPOSIXWorkerWakeup(
      readDescriptor: readDescriptor,
      writeDescriptor: writeDescriptor
    )
  }

  package static func signalWakeup(
    _ wakeup: MojoPOSIXWorkerWakeup
  ) throws {
    try requireSupported(operation: "signal worker wakeup")
    var errorCode: Int32 = 0
    guard
      swift_mojo_posix_worker_signal_wakeup(
        wakeup.writeDescriptor,
        &errorCode
      ) == 0
    else {
      throw failure(operation: "signal worker wakeup", code: errorCode)
    }
  }

  /// Drains all currently queued wakeup bytes without blocking.
  ///
  /// The wakeup descriptor is owned by the cancellation gate. This function
  /// only borrows it for the synchronous read loop; it never closes or
  /// retains the descriptor.
  package static func drainWakeup(
    _ wakeup: MojoPOSIXWorkerWakeup
  ) throws -> MojoPOSIXWorkerWakeupDrain {
    try requireSupported(operation: "drain worker wakeup")
    let maximumBytes = 4_096
    let maximumReads = 16
    var consumedBytes = 0
    var storage = [UInt8](repeating: 0, count: 256)
    for _ in 0..<maximumReads {
      let remaining = maximumBytes - consumedBytes
      guard remaining > 0 else {
        return MojoPOSIXWorkerWakeupDrain(
          consumedBytes: consumedBytes,
          limitReached: true
        )
      }
      let readCount = min(storage.count, remaining)
      let result = try storage.withUnsafeMutableBytes { bytes in
        let bounded = UnsafeMutableRawBufferPointer(
          rebasing: bytes[..<(readCount)]
        )
        return try read(
          descriptor: wakeup.readDescriptor,
          into: bounded
        )
      }
      switch result {
      case .bytes(let count):
        consumedBytes += count
      case .wouldBlock, .eof:
        return MojoPOSIXWorkerWakeupDrain(
          consumedBytes: consumedBytes,
          limitReached: false
        )
      case .interrupted:
        continue
      }
    }
    return MojoPOSIXWorkerWakeupDrain(
      consumedBytes: consumedBytes,
      limitReached: true
    )
  }

  package static func poll(
    protocolDescriptor: Int32,
    diagnosticDescriptor: Int32,
    wakeupDescriptor: Int32? = nil,
    interests: MojoPOSIXWorkerPollInterest,
    timeout: Duration
  ) throws -> MojoPOSIXWorkerPollResult {
    try requireSupported(operation: "poll worker descriptors")
    let timeoutMilliseconds = try timeoutMilliseconds(for: timeout)
    var eventMask: Int32 = 0
    var errorCode: Int32 = 0
    let result = swift_mojo_posix_worker_poll(
      protocolDescriptor,
      diagnosticDescriptor,
      wakeupDescriptor ?? -1,
      interests.rawValue,
      timeoutMilliseconds,
      &eventMask,
      &errorCode
    )
    if result == 0 { return .timedOut }
    if result == 1 {
      return .ready(MojoPOSIXWorkerPollEvents(rawValue: eventMask))
    }
    if swift_mojo_posix_error_is_interrupted(errorCode) == 1 {
      return .interrupted
    }
    throw failure(operation: "poll worker descriptors", code: errorCode)
  }

  package static func read(
    descriptor: Int32,
    into buffer: UnsafeMutableRawBufferPointer
  ) throws -> MojoPOSIXWorkerIOResult {
    guard buffer.count > 0, buffer.baseAddress != nil else {
      throw MojoPOSIXWorkerSupportError.invalidBuffer
    }
    try requireSupported(operation: "read worker descriptor")
    var errorCode: Int32 = 0
    let count = swift_mojo_posix_worker_read(
      descriptor,
      buffer.baseAddress,
      Int64(buffer.count),
      &errorCode
    )
    if count > 0 { return .bytes(Int(count)) }
    if count == 0 { return .eof }
    if swift_mojo_posix_error_is_interrupted(errorCode) == 1 {
      return .interrupted
    }
    if swift_mojo_posix_error_is_would_block(errorCode) == 1 {
      return .wouldBlock
    }
    throw failure(operation: "read worker descriptor", code: errorCode)
  }

  package static func write(
    descriptor: Int32,
    from buffer: UnsafeRawBufferPointer
  ) throws -> MojoPOSIXWorkerIOResult {
    guard buffer.count > 0, buffer.baseAddress != nil else {
      throw MojoPOSIXWorkerSupportError.invalidBuffer
    }
    try requireSupported(operation: "write worker descriptor")
    var errorCode: Int32 = 0
    let count = swift_mojo_posix_worker_write(
      descriptor,
      buffer.baseAddress,
      Int64(buffer.count),
      &errorCode
    )
    if count > 0 { return .bytes(Int(count)) }
    if count == 0 { return .eof }
    if swift_mojo_posix_error_is_interrupted(errorCode) == 1 {
      return .interrupted
    }
    if swift_mojo_posix_error_is_would_block(errorCode) == 1 {
      return .wouldBlock
    }
    throw failure(operation: "write worker descriptor", code: errorCode)
  }

  package static func closeDescriptor(_ descriptor: Int32) throws {
    try MojoPOSIXSupport.closeFile(descriptor)
  }

  private static func timeoutMilliseconds(for timeout: Duration) throws -> Int32 {
    let components = timeout.components
    guard components.seconds >= 0, components.attoseconds >= 0 else {
      throw MojoPOSIXWorkerSupportError.invalidTimeout
    }
    let attosecondsPerMillisecond: Int64 = 1_000_000_000_000_000
    let seconds = components.seconds
    let wholeMillisecondsLimit = Int64(Int32.max) / 1_000
    guard seconds <= wholeMillisecondsLimit else {
      throw MojoPOSIXWorkerSupportError.invalidTimeout
    }
    let wholeMilliseconds = seconds * 1_000
    let fractionalMilliseconds =
      components.attoseconds == 0
      ? 0
      : (components.attoseconds + attosecondsPerMillisecond - 1)
        / attosecondsPerMillisecond
    guard wholeMilliseconds <= Int64(Int32.max) - fractionalMilliseconds else {
      throw MojoPOSIXWorkerSupportError.invalidTimeout
    }
    return Int32(wholeMilliseconds + fractionalMilliseconds)
  }

  private static func requireSupported(operation: String) throws {
    guard isSupported else {
      throw MojoPOSIXSupportError.unsupportedPlatform(operation: operation)
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

private final class MojoPOSIXWorkerCStringArray {
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
