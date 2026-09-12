package enum MojoPOSIXRightsError: Error, Equatable, Sendable {
  case invalidBuffer
  case occupiedDescriptorSlots
  case operationFailed(code: Int32, cleanupCode: Int32)
}

/// Synchronous, nonblocking ancillary I/O. The caller owns all descriptors.
package enum MojoPOSIXRightsSupport {
  /// A positive byte count commits the entire rights set; never resend it.
  package static func send(
    descriptor: Int32, bytes: UnsafeRawBufferPointer, rights: [Int32]
  ) throws -> MojoPOSIXWorkerIOResult {
    guard !bytes.isEmpty, bytes.baseAddress != nil,
      !rights.isEmpty, rights.count <= Int(UInt16.max)
    else { throw MojoPOSIXRightsError.invalidBuffer }
    var error: Int32 = 0
    let count = rights.withUnsafeBufferPointer { descriptors in
      swift_mojo_posix_send_rights(
        descriptor, bytes.baseAddress, Int64(bytes.count),
        descriptors.baseAddress, UInt16(descriptors.count), &error
      )
    }
    return try result(count: count, error: error, cleanupError: 0)
  }

  /// On success, the first descriptorCount slots transfer to the caller.
  /// On failure, native code consumes every received descriptor exactly once.
  package static func receive(
    descriptor: Int32, bytes: UnsafeMutableRawBufferPointer,
    rights: inout [Int32]
  ) throws -> (result: MojoPOSIXWorkerIOResult, descriptorCount: Int) {
    guard !bytes.isEmpty, bytes.baseAddress != nil,
      rights.count <= Int(UInt16.max)
    else { throw MojoPOSIXRightsError.invalidBuffer }
    guard rights.allSatisfy({ $0 == -1 }) else {
      throw MojoPOSIXRightsError.occupiedDescriptorSlots
    }
    var error: Int32 = 0
    var cleanupError: Int32 = 0
    var descriptorCount: UInt16 = 0
    let count = rights.withUnsafeMutableBufferPointer { descriptors in
      swift_mojo_posix_receive_rights(
        descriptor, bytes.baseAddress, Int64(bytes.count),
        descriptors.baseAddress, UInt16(descriptors.count),
        &descriptorCount, &error, &cleanupError
      )
    }
    return (
      try result(count: count, error: error, cleanupError: cleanupError),
      Int(descriptorCount)
    )
  }

  private static func result(
    count: Int64, error: Int32, cleanupError: Int32
  ) throws -> MojoPOSIXWorkerIOResult {
    if count > 0 { return .bytes(Int(count)) }
    if count == 0 { return .eof }
    if cleanupError == 0 {
      if swift_mojo_posix_error_is_interrupted(error) == 1 { return .interrupted }
      if swift_mojo_posix_error_is_would_block(error) == 1 { return .wouldBlock }
    }
    throw MojoPOSIXRightsError.operationFailed(code: error, cleanupCode: cleanupError)
  }
}
