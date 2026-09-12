import Foundation
import MojoPOSIXSupport
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("Native ancillary descriptor transfer")
struct MojoPOSIXRightsTests {
  @Test(.timeLimit(.minutes(1)))
  func partialSendCommitsRightsOnlyOnce() throws {
    try withSockets { sockets in
      var capacity: Int32 = 4096
      try #require(setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &capacity, 4) == 0)
      let payload = [UInt8](repeating: 7, count: 1_048_576)
      let sent = try payload.withUnsafeBytes {
        try MojoPOSIXRightsSupport.send(descriptor: sockets[0], bytes: $0, rights: [sockets[0]])
      }
      guard case .bytes(let count) = sent else {
        Issue.record("Expected partial positive send, got \(sent)")
        return
      }
      #expect(count > 0 && count < payload.count)
      var byte = [UInt8(0)]
      var rights: [Int32] = [-1]
      let first = try byte.withUnsafeMutableBytes {
        try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
      }
      #expect(first.descriptorCount == 1)
      defer { if rights[0] >= 0 { #expect(close(rights[0]) == 0) } }
      var received = 1
      var buffer = [UInt8](repeating: 0, count: 4096)
      var noRights: [Int32] = []
      while received < count {
        let tail = try buffer.withUnsafeMutableBytes {
          try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &noRights)
        }
        guard case .bytes(let amount) = tail.result else {
          Issue.record("Expected remaining committed payload, got \(tail.result)")
          break
        }
        #expect(tail.descriptorCount == 0)
        received += amount
      }
      #expect(received == count)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func transfersBackingAndCloseOnExecWithoutClosingSource() throws {
    try withSockets { sockets in
      let source = open("/dev/null", O_RDONLY | O_CLOEXEC)
      #expect(source >= 0)
      defer { #expect(close(source) == 0) }
      let sent = try [UInt8(42), 43].withUnsafeBytes {
        try MojoPOSIXRightsSupport.send(descriptor: sockets[0], bytes: $0, rights: [source])
      }
      #expect(sent == .bytes(2))
      var bytes = [UInt8](repeating: 0, count: 1)
      var rights: [Int32] = [-1]
      let received = try bytes.withUnsafeMutableBytes {
        try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
      }
      #expect(received.result == .bytes(1))
      #expect(received.descriptorCount == 1)
      #expect(bytes == [42])
      let imported = try #require(rights.first)
      defer { #expect(close(imported) == 0) }
      #expect(imported != source)
      #expect(fcntl(imported, F_GETFD) & FD_CLOEXEC != 0)
      #expect(fcntl(source, F_GETFD) >= 0)
      var sourceStat = stat()
      var importedStat = stat()
      #expect(fstat(source, &sourceStat) == 0)
      #expect(fstat(imported, &importedStat) == 0)
      #expect(sourceStat.st_dev == importedStat.st_dev)
      #expect(sourceStat.st_ino == importedStat.st_ino)
      rights = []
      let tail = try bytes.withUnsafeMutableBytes {
        try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
      }
      #expect(tail.result == .bytes(1))
      #expect(tail.descriptorCount == 0)
      #expect(bytes == [43])
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func unexpectedAndTruncatedRightsAreConsumed() throws {
    try withSockets { sockets in
      let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
      let source = open(path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
      defer { #expect(unlink(path) == 0) }
      #expect(source >= 0)
      defer { #expect(close(source) == 0) }
      var identity = stat()
      try #require(fstat(source, &identity) == 0)
      // Count only this unique file's descriptors; other tests may open files.
      func matchingDescriptors() -> Int {
        var count = 0
        for descriptor: Int32 in 0..<4096 {
          var candidate = stat()
          if fstat(descriptor, &candidate) == 0,
            candidate.st_dev == identity.st_dev, candidate.st_ino == identity.st_ino {
            count += 1
          }
        }
        return count
      }
      try #require(source < 4096)
      #expect(matchingDescriptors() == 1)
      for capacity in [0, 1] {
        for _ in 0..<256 {
          _ = try [UInt8(1)].withUnsafeBytes {
            try MojoPOSIXRightsSupport.send(
              descriptor: sockets[0], bytes: $0, rights: [source, source, source, source]
            )
          }
          var bytes = [UInt8(0)]
          var rights = [Int32](repeating: -1, count: capacity)
          #expect(throws: MojoPOSIXRightsError.operationFailed(code: EPROTO, cleanupCode: 0)) {
            try bytes.withUnsafeMutableBytes {
              try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
            }
          }
          #expect(rights.allSatisfy { $0 == -1 })
        }
      }
      #expect(matchingDescriptors() == 1)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func distinguishesWouldBlockEOFAndFailure() throws {
    try withSockets { sockets in
      var bytes = [UInt8(0)]
      var rights: [Int32] = []
      let empty = try bytes.withUnsafeMutableBytes {
        try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
      }
      #expect(empty.result == .wouldBlock)
      #expect(shutdown(sockets[0], Int32(SHUT_WR)) == 0)
      let ended = try bytes.withUnsafeMutableBytes {
        try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
      }
      #expect(ended.result == .eof)
      #expect(throws: MojoPOSIXRightsError.operationFailed(code: EBADF, cleanupCode: 0)) {
        try bytes.withUnsafeBytes {
          try MojoPOSIXRightsSupport.send(descriptor: -1, bytes: $0, rights: [sockets[0]])
        }
      }
      rights = [sockets[0]]
      #expect(throws: MojoPOSIXRightsError.occupiedDescriptorSlots) {
        try bytes.withUnsafeMutableBytes {
          try MojoPOSIXRightsSupport.receive(descriptor: sockets[1], bytes: $0, rights: &rights)
        }
      }
      #expect(fcntl(sockets[0], F_GETFD) >= 0)
      let flags = fcntl(sockets[0], F_GETFL)
      try #require(flags >= 0)
      try #require(fcntl(sockets[0], F_SETFL, flags & ~O_NONBLOCK) == 0)
      #expect(throws: MojoPOSIXRightsError.operationFailed(code: EINVAL, cleanupCode: 0)) {
        try bytes.withUnsafeBytes {
          try MojoPOSIXRightsSupport.send(descriptor: sockets[0], bytes: $0, rights: [sockets[1]])
        }
      }
    }
  }

  private func withSockets(_ body: ([Int32]) throws -> Void) throws {
    var sockets: [Int32] = [-1, -1]
    #if canImport(Darwin)
    let kind = SOCK_STREAM
    #else
    let kind = Int32(SOCK_STREAM.rawValue)
    #endif
    try #require(socketpair(AF_UNIX, kind, 0, &sockets) == 0)
    defer { for socket in sockets { #expect(close(socket) == 0) } }
    for socket in sockets {
      let flags = fcntl(socket, F_GETFL)
      try #require(flags >= 0)
      try #require(fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0)
    }
    #if canImport(Darwin)
    var enabled: Int32 = 1
    for socket in sockets {
      try #require(setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0)
    }
    #endif
    try body(sockets)
  }
}
