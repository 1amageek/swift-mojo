import Foundation
import MojoPOSIXSupport
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Native readonly shared input")
struct MojoPOSIXSharedInputTests {
  @Test(.timeLimit(.minutes(1)))
  func mapsOriginalBackingAndRejectsWritableAdmission() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let writer = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    try #require(writer >= 0)
    defer {
      #expect(close(writer) == 0)
      #expect(unlink(path) == 0)
    }
    let payload: [UInt8] = [7, 19, 253, 41]
    #expect(payload.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) } == 4)
    let reader = open(path, O_RDONLY | O_CLOEXEC)
    try #require(reader >= 0)
    defer { #expect(close(reader) == 0) }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "duplicate", code: EACCES, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: writer, kind: 2, byteCount: 4)
    }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "duplicate", code: EINVAL, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: reader, kind: 2, byteCount: 5)
    }
    let duplicate = try MojoPOSIXSharedInputSupport.duplicate(descriptor: reader, kind: 2, byteCount: 4)
    defer { #expect(close(duplicate) == 0) }
    #expect(fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)
    let mapping = try MojoPOSIXSharedInputSupport.map(descriptor: duplicate, byteCount: 4)
    defer {
      do { try MojoPOSIXSharedInputSupport.unmap(mapping) }
      catch { Issue.record("Unmap failed: \(error)") }
    }
    #expect(Array(mapping) == payload)
    // A fixture-only writer mutation proves backing identity rather than a copy.
    // Production's retained producer lease forbids mutation while readers exist.
    var updated: UInt8 = 99
    #expect(pwrite(writer, &updated, 1, 2) == 1)
    #expect(mapping[2] == 99)
    // The OS must reject upgrading this readonly descriptor mapping to writable.
    #expect(mprotect(UnsafeMutableRawPointer(mutating: mapping.baseAddress), mapping.count, PROT_READ | PROT_WRITE) == -1)
    #expect(fcntl(reader, F_GETFD) >= 0)
  }

  @Test(.timeLimit(.minutes(1)))
  func invalidResourcesFailExplicitly() throws {
    #expect(throws: MojoPOSIXSharedInputError.invalidExtent) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: -1, kind: 2, byteCount: 0)
    }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "duplicate", code: EBADF, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: -1, kind: 2, byteCount: 4)
    }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "map", code: EBADF, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.map(descriptor: -1, byteCount: 4)
    }
    let device = open("/dev/null", O_RDONLY | O_CLOEXEC)
    try #require(device >= 0)
    defer { #expect(close(device) == 0) }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "duplicate", code: EINVAL, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: device, kind: 2, byteCount: 4)
    }
    #if canImport(Darwin)
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "duplicate", code: ENOTSUP, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.duplicate(descriptor: device, kind: 3, byteCount: 4)
    }
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "synchronize", code: ENOTSUP, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.synchronize(descriptor: device, ending: false)
    }
    #else
    #expect(throws: MojoPOSIXSharedInputError.operationFailed(operation: "synchronize", code: ENOTTY, cleanupCode: 0)) {
      try MojoPOSIXSharedInputSupport.synchronize(descriptor: device, ending: false)
    }
    #endif
  }
}
