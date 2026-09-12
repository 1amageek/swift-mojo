import Foundation
import MojoRuntimeWorker
import MojoRuntimeWorkerPOSIX
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Public native input ownership")
struct MojoPOSIXSharedInputTests {
  @Test(.timeLimit(.minutes(1)))
  func retainsProducerAndConsumesOnlyItsDuplicate() throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try Data([1, 3, 5, 7]).write(to: URL(fileURLWithPath: path))
    defer { #expect(unlink(path) == 0) }
    let source = open(path, O_RDONLY | O_CLOEXEC)
    try #require(source >= 0 && source < 4096)
    defer { #expect(close(source) == 0) }
    var identity = stat()
    try #require(fstat(source, &identity) == 0)
    func references() -> Int {
      var result = 0
      for fd: Int32 in 0..<4096 {
        var candidate = stat()
        if fstat(fd, &candidate) == 0,
          candidate.st_dev == identity.st_dev, candidate.st_ino == identity.st_ino {
          result += 1
        }
      }
      return result
    }
    let counter = ReleaseCounter()
    var producer: Producer? = Producer(counter: counter)
    var buffer: MojoReadOnlyBuffer? = try MojoPOSIXSharedInput.importReadOnly(
      descriptor: source, byteCount: 4, retaining: try #require(producer), kind: .regularFile
    )
    producer = nil
    withExtendedLifetime(buffer) {
      #expect(buffer?.byteCount == 4)
      #expect(counter.count == 0)
      #expect(references() == 2)
    }
    buffer = nil
    #expect(counter.count == 1)
    #expect(references() == 1)
    #expect(fcntl(source, F_GETFD) >= 0)
    #expect(lseek(source, 2, SEEK_SET) == 2)
    #if canImport(Darwin)
    let wrongKindError: Int32 = ENOTSUP
    #else
    let wrongKindError: Int32 = ENOTTY
    #endif
    #expect(throws: MojoPOSIXInputError.nativeFailure(operation: "duplicate", code: wrongKindError, cleanupCode: 0)) {
      try MojoPOSIXSharedInput.importReadOnly(
        descriptor: source, byteCount: 4, retaining: Producer(counter: ReleaseCounter()), kind: .dmaBuf
      )
    }
    #expect(lseek(source, 0, SEEK_CUR) == 2)
    #expect(references() == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsInvalidNativeAdmissionWithoutRetainingProducer() throws {
    let counter = ReleaseCounter()
    do {
      let producer = Producer(counter: counter)
      #expect(throws: MojoPOSIXInputError.nativeFailure(operation: "duplicate", code: EBADF, cleanupCode: 0)) {
        try MojoPOSIXSharedInput.importReadOnly(descriptor: -1, byteCount: 4, retaining: producer, kind: .regularFile)
      }
    }
    #expect(counter.count == 1)
  }

  @Test(.timeLimit(.minutes(1)))
  func hostStorageIsExplicitAndRetainedWithoutMaterialization() throws {
    let counter = ReleaseCounter()
    var producer: HostSource? = HostSource(counter: counter)
    var buffer: MojoReadOnlyBuffer? = try MojoReadOnlyBuffer(hostSource: try #require(producer))
    producer = nil
    withExtendedLifetime(buffer) {
      #expect(buffer?.byteCount == 4)
      #expect(counter.count == 0)
      #expect(counter.borrows.withLock { $0 } == 0)
    }
    buffer = nil
    #expect(counter.count == 1)
    #expect(try MojoReadOnlyBuffer(hostSource: Data()).byteCount == 0)
    #expect(throws: MojoBufferError.invalidByteCount) {
      try MojoReadOnlyBuffer(hostSource: HostSource(counter: ReleaseCounter(), byteCount: -1))
    }
  }
}

private final class ReleaseCounter: Sendable {
  let releases = Mutex(0)
  let borrows = Mutex(0)
  var count: Int { releases.withLock { $0 } }
}

private final class Producer: Sendable {
  let counter: ReleaseCounter
  init(counter: ReleaseCounter) { self.counter = counter }
  deinit { counter.releases.withLock { $0 += 1 } }
}

private final class HostSource: MojoBufferSource {
  let counter: ReleaseCounter
  let bytes = Data([1, 2, 3, 4])
  let byteCount: Int
  init(counter: ReleaseCounter, byteCount: Int = 4) {
    self.counter = counter
    self.byteCount = byteCount
  }
  func withUnsafeBytes<Result>(_ body: (UnsafeRawBufferPointer) throws -> Result) throws -> Result {
    counter.borrows.withLock { $0 += 1 }
    return try bytes.withUnsafeBytes(body)
  }
  deinit { counter.releases.withLock { $0 += 1 } }
}
