package enum MojoPOSIXSharedInputError: Error, Equatable, Sendable {
  case invalidExtent
  case operationFailed(operation: String, code: Int32, cleanupCode: Int32)
}

package enum MojoPOSIXSynchronizationResult: Equatable, Sendable {
  case completed
  case interrupted
  case wouldBlock
}

/// Native primitives; the importing owner retains the producer and closes the
/// returned duplicate. DMA-BUF identity is qualified before size discovery.
package enum MojoPOSIXSharedInputSupport {
  package static func duplicate(
    descriptor: Int32, kind: UInt16, byteCount: Int
  ) throws -> Int32 {
    guard byteCount > 0 else { throw MojoPOSIXSharedInputError.invalidExtent }
    var error: Int32 = 0
    var cleanup: Int32 = 0
    let duplicate = swift_mojo_posix_shared_duplicate(
      descriptor, kind, UInt64(byteCount), &error, &cleanup
    )
    guard duplicate >= 0 else {
      throw MojoPOSIXSharedInputError.operationFailed(
        operation: "duplicate", code: error, cleanupCode: cleanup
      )
    }
    return duplicate
  }

  /// Interruption and would-block are retryable under the owner's deadline.
  package static func synchronize(descriptor: Int32, ending: Bool) throws -> MojoPOSIXSynchronizationResult {
    var error: Int32 = 0
    if swift_mojo_posix_shared_sync(descriptor, ending ? 1 : 0, &error) == 0 { return .completed }
    if swift_mojo_posix_error_is_interrupted(error) == 1 { return .interrupted }
    if swift_mojo_posix_error_is_would_block(error) == 1 { return .wouldBlock }
    throw MojoPOSIXSharedInputError.operationFailed(operation: "synchronize", code: error, cleanupCode: 0)
  }

  /// Mapping ownership transfers to the caller, which must join readers before
  /// unmapping. This package-only pointer never crosses the public boundary.
  package static func map(descriptor: Int32, byteCount: Int) throws -> UnsafeRawBufferPointer {
    guard byteCount > 0 else { throw MojoPOSIXSharedInputError.invalidExtent }
    var error: Int32 = 0
    guard let address = swift_mojo_posix_shared_map(descriptor, UInt64(byteCount), &error) else {
      throw MojoPOSIXSharedInputError.operationFailed(operation: "map", code: error, cleanupCode: 0)
    }
    return UnsafeRawBufferPointer(start: address, count: byteCount)
  }

  package static func unmap(_ buffer: UnsafeRawBufferPointer) throws {
    guard !buffer.isEmpty, buffer.baseAddress != nil else { throw MojoPOSIXSharedInputError.invalidExtent }
    var error: Int32 = 0
    guard swift_mojo_posix_shared_unmap(buffer.baseAddress, UInt64(buffer.count), &error) == 0 else {
      throw MojoPOSIXSharedInputError.operationFailed(operation: "unmap", code: error, cleanupCode: 0)
    }
  }
}
