import Foundation
import MojoPOSIXSupport
import Testing

@Suite("POSIX worker support")
struct MojoPOSIXWorkerSupportTests {
  @Test(.timeLimit(.minutes(1)))
  func workerMapsProtocolToChildFileDescriptorThreeAndCapturesDiagnostics() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: [
        "-c",
        "if IFS= read -r unexpected; then exit 91; fi; printf ready >&3; printf diagnostic >&2; IFS= read -r line <&3; printf '%s\\n' \"$line\" >&3",
      ]
    )
    defer {
      cleanup(worker)
    }

    let ready: Data
    do {
      ready = try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 5
      )
    } catch {
      let diagnostics = try readUntilEOF(
        descriptor: worker.diagnosticDescriptor
      )
      throw TestFailure(
        "Protocol startup failed: \(error); diagnostics="
          + String(decoding: diagnostics, as: UTF8.self)
      )
    }
    #expect(ready == Data("ready".utf8))
    #expect(
      try writeAll(
        descriptor: worker.protocolDescriptor,
        data: Data("ping\n".utf8)
      ) == 5
    )
    let echo: Data
    do {
      echo = try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 5
      )
    } catch {
      let diagnostics = try readUntilEOF(
        descriptor: worker.diagnosticDescriptor
      )
      throw TestFailure(
        "Protocol echo failed: \(error); diagnostics="
          + String(decoding: diagnostics, as: UTF8.self)
      )
    }
    #expect(echo == Data("ping\n".utf8))
    #expect(
      try readUntilEOF(
        descriptor: worker.diagnosticDescriptor
      ) == Data("diagnostic".utf8)
    )
    _ = try waitForReap(worker.processID)
  }

  @Test(.timeLimit(.minutes(1)))
  func workerPollAllowsDiagnosticDrainWhileProtocolRemainsLive() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: [
        "-c",
        "dd if=/dev/zero bs=4096 count=32 1>&2 2>/dev/null; printf ready >&3; sleep 1",
      ]
    )
    defer {
      cleanup(worker)
    }

    var diagnosticByteCount = 0
    var protocolReady = false
    while !protocolReady {
      let events = try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: worker.protocolDescriptor,
        diagnosticDescriptor: worker.diagnosticDescriptor,
        interests: [.read],
        timeout: .seconds(3)
      )
      guard case .ready(let readyEvents) = events else {
        throw TestFailure("Worker did not produce a live event: \(events)")
      }
      if readyEvents.contains(.diagnosticReadable) {
        diagnosticByteCount += try drainAvailable(
          descriptor: worker.diagnosticDescriptor
        )
      }
      if readyEvents.contains(.protocolReadable) {
        #expect(
          try readExactly(
            descriptor: worker.protocolDescriptor,
            count: 5
          ) == Data("ready".utf8)
        )
        protocolReady = true
      }
    }
    #expect(diagnosticByteCount >= 32 * 4096)
  }

  @Test(.timeLimit(.minutes(1)))
  func workerPollReportsTimeoutAndFragmentedReads() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: ["-c", "sleep 1; printf abc >&3; sleep 1; printf def >&3"]
    )
    defer {
      cleanup(worker)
    }

    #expect(
      try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: worker.protocolDescriptor,
        diagnosticDescriptor: worker.diagnosticDescriptor,
        interests: [.read],
        timeout: .milliseconds(25)
      ) == .timedOut
    )
    #expect(
      try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 3,
        timeout: .seconds(3)
      ) == Data("abc".utf8)
    )
    #expect(
      try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 3,
        timeout: .seconds(3)
      ) == Data("def".utf8)
    )
    _ = try waitForReap(worker.processID)
  }

  @Test(.timeLimit(.minutes(1)))
  func workerWakeupIsPollableAndClosedPeerSignalIsTyped() throws {
    let wakeup = try MojoPOSIXWorkerSupport.createWakeup()
    var descriptorsToClose = [
      wakeup.readDescriptor,
      wakeup.writeDescriptor,
    ]
    defer {
      for descriptor in descriptorsToClose {
        do {
          try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
        } catch {
          Issue.record("Failed to close wakeup descriptor: \(error)")
        }
      }
    }

    let clock = ContinuousClock()
    let timeoutStart = clock.now
    #expect(
      try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: -1,
        diagnosticDescriptor: -1,
        wakeupDescriptor: wakeup.readDescriptor,
        interests: [],
        timeout: .milliseconds(150)
      ) == .timedOut
    )
    #expect(
      timeoutStart.duration(to: clock.now) >= .milliseconds(100)
    )

    try MojoPOSIXWorkerSupport.signalWakeup(wakeup)
    let events = try readyEvents(
      from: MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: -1,
        diagnosticDescriptor: -1,
        wakeupDescriptor: wakeup.readDescriptor,
        interests: [],
        timeout: .seconds(1)
      )
    )
    #expect(events.contains(.wakeupReadable))

    var token: UInt8 = 0
    #expect(
      try withUnsafeMutableBytes(of: &token) { bytes in
        try MojoPOSIXWorkerSupport.read(
          descriptor: wakeup.readDescriptor,
          into: bytes
        )
      } == .bytes(1)
    )
    #expect(token == 1)

    descriptorsToClose.removeAll { $0 == wakeup.readDescriptor }
    try MojoPOSIXWorkerSupport.closeDescriptor(wakeup.readDescriptor)
    do {
      try MojoPOSIXWorkerSupport.signalWakeup(wakeup)
      Issue.record("A wakeup with a closed peer unexpectedly succeeded")
    } catch let error as MojoPOSIXSupportError {
      guard case .operationFailed(let operation, _) = error else {
        Issue.record("Unexpected closed-wakeup error: \(error)")
        return
      }
      #expect(operation == "signal worker wakeup")
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func workerWakeupDrainIsBoundedAndContinuesAfterShortReads() throws {
    let wakeup = try MojoPOSIXWorkerSupport.createWakeup()
    defer {
      for descriptor in [wakeup.readDescriptor, wakeup.writeDescriptor] {
        do {
          try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
        } catch {
          Issue.record("Failed to close wakeup fixture: \(error)")
        }
      }
    }

    for _ in 0..<5_000 {
      try MojoPOSIXWorkerSupport.signalWakeup(wakeup)
    }
    let first = try MojoPOSIXWorkerSupport.drainWakeup(wakeup)
    #expect(first.consumedBytes == 4_096)
    #expect(first.limitReached)
    let second = try MojoPOSIXWorkerSupport.drainWakeup(wakeup)
    #expect(second.consumedBytes > 0)
    #expect(!second.limitReached)
  }

  @Test(.timeLimit(.minutes(1)))
  func workerIORejectsEmptyBuffersWithoutReportingEOF() throws {
    do {
      _ = try MojoPOSIXWorkerSupport.read(
        descriptor: -1,
        into: UnsafeMutableRawBufferPointer(start: nil, count: 0)
      )
      Issue.record("An empty read buffer unexpectedly succeeded")
    } catch let error as MojoPOSIXWorkerSupportError {
      #expect(error == .invalidBuffer)
    }

    do {
      _ = try MojoPOSIXWorkerSupport.write(
        descriptor: -1,
        from: UnsafeRawBufferPointer(start: nil, count: 0)
      )
      Issue.record("An empty write buffer unexpectedly succeeded")
    } catch let error as MojoPOSIXWorkerSupportError {
      #expect(error == .invalidBuffer)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func workerReadReportsEOFAndClosedPeerWriteIsAnErrorNotProcessTermination() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: ["-c", "exit 0"]
    )
    defer {
      cleanup(worker)
    }

    _ = try waitForReap(worker.processID)
    let pollResult = try MojoPOSIXWorkerSupport.poll(
      protocolDescriptor: worker.protocolDescriptor,
      diagnosticDescriptor: worker.diagnosticDescriptor,
      interests: [.read, .write],
      timeout: .seconds(1)
    )
    let events = try readyEvents(from: pollResult)
    #expect(events.contains(.protocolHangup) || events.contains(.protocolError))
    var byte: UInt8 = 0
    #expect(
      try withUnsafeMutableBytes(of: &byte) { bytes in
        try MojoPOSIXWorkerSupport.read(
          descriptor: worker.protocolDescriptor,
          into: bytes
        )
      } == .eof
    )
    do {
      _ = try withUnsafeBytes(of: &byte) { bytes in
        try MojoPOSIXWorkerSupport.write(
          descriptor: worker.protocolDescriptor,
          from: bytes
        )
      }
      Issue.record("A closed worker peer unexpectedly accepted a write")
    } catch let error as MojoPOSIXSupportError {
      guard case .operationFailed = error else {
        Issue.record("Unexpected closed-peer error: \(error)")
        return
      }
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func workerProcessGroupCanBeKilledAndReaped() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: ["-c", "sleep 30 & printf ready >&3; wait"]
    )
    defer {
      cleanup(worker)
    }

    _ = try readExactly(
      descriptor: worker.protocolDescriptor,
      count: 5
    )
    try MojoPOSIXSupport.signalProcessGroup(
      processID: worker.processID,
      signal: MojoPOSIXSupport.killSignal
    )
    _ = try waitForReap(worker.processID, timeout: .seconds(3))
    #expect(!MojoPOSIXSupport.processGroupIsAlive(worker.processID))
  }

  @Test(.timeLimit(.minutes(1)))
  func workerSpawnDeliversTerminationToAChildInstalledHandler() throws {
    let worker = try MojoPOSIXWorkerSupport.spawn(
      executablePath: "/bin/sh",
      arguments: [
        "-c",
        "trap 'printf term >&3; exit 0' TERM; printf ready >&3; while :; do :; done",
      ]
    )
    defer {
      cleanup(worker)
    }

    #expect(
      try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 5
      ) == Data("ready".utf8)
    )
    try MojoPOSIXSupport.signalProcessGroup(
      processID: worker.processID,
      signal: MojoPOSIXSupport.terminationSignal
    )
    #expect(
      try readExactly(
        descriptor: worker.protocolDescriptor,
        count: 4
      ) == Data("term".utf8)
    )
    _ = try waitForReap(worker.processID)
    #expect(!MojoPOSIXSupport.processGroupIsAlive(worker.processID))
  }

  @Test(.timeLimit(.minutes(1)))
  func existingToolSpawnStillUsesItsOutputFileContract() throws {
    let outputURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
    let outputDescriptor = try MojoPOSIXSupport.openOutputFile(
      path: outputURL.path
    )
    defer {
      do {
        try MojoPOSIXSupport.closeFile(outputDescriptor)
      } catch {
        Issue.record("Failed to close tool output: \(error)")
      }
      do {
        try FileManager.default.removeItem(at: outputURL)
      } catch {
        Issue.record("Failed to remove tool output: \(error)")
      }
    }

    let processID = try MojoPOSIXSupport.spawn(
      executablePath: "/bin/sh",
      arguments: ["-c", "printf tool"],
      environment: nil,
      outputDescriptor: outputDescriptor
    )
    _ = try waitForReap(processID)
    try MojoPOSIXSupport.seekToStart(outputDescriptor)
    #expect(
      try MojoPOSIXSupport.readOutput(outputDescriptor)
        == Data("tool".utf8)
    )
  }

  private func cleanup(_ worker: MojoPOSIXWorkerProcess) {
    var requiresTermination = true
    do {
      if try MojoPOSIXSupport.waitNoHang(processID: worker.processID) != nil {
        requiresTermination = false
      }
    } catch let error as MojoPOSIXSupportError {
      if error == .childAlreadyReaped {
        requiresTermination = false
      } else {
        Issue.record("Failed to inspect worker fixture: \(error)")
      }
    } catch {
      Issue.record("Failed to inspect worker fixture: \(error)")
    }
    if requiresTermination {
      var signalFailure: Error?
      do {
        try MojoPOSIXSupport.signalProcessGroup(
          processID: worker.processID,
          signal: MojoPOSIXSupport.killSignal
        )
      } catch {
        signalFailure = error
      }
      do {
        _ = try waitForReap(worker.processID)
      } catch {
        Issue.record(
          "Failed to reap worker fixture: \(error); signalFailure=\(String(describing: signalFailure))"
        )
      }
    }
    for descriptor in [
      worker.protocolDescriptor,
      worker.diagnosticDescriptor,
    ] {
      do {
        try MojoPOSIXWorkerSupport.closeDescriptor(descriptor)
      } catch {
        Issue.record("Failed to close worker descriptor: \(error)")
      }
    }
  }

  private func readExactly(
    descriptor: Int32,
    count: Int,
    timeout: Duration = .seconds(2)
  ) throws -> Data {
    var data = Data()
    while data.count < count {
      let events = try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: descriptor,
        diagnosticDescriptor: -1,
        interests: [.read],
        timeout: timeout
      )
      let readyEvents = try readyEvents(from: events)
      guard readyEvents.contains(.protocolReadable) else {
        throw TestFailure("Protocol did not become readable: \(events)")
      }
      let remaining = count - data.count
      var buffer = [UInt8](repeating: 0, count: remaining)
      let result = try buffer.withUnsafeMutableBytes { bytes in
        return try MojoPOSIXWorkerSupport.read(
          descriptor: descriptor,
          into: bytes
        )
      }
      switch result {
      case .bytes(let count):
        data.append(buffer, count: count)
      case .eof:
        throw TestFailure("Unexpected protocol EOF")
      case .interrupted:
        continue
      case .wouldBlock:
        continue
      }
    }
    return data
  }

  private func readUntilEOF(descriptor: Int32) throws -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 256)
    while true {
      let events = try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: -1,
        diagnosticDescriptor: descriptor,
        interests: [],
        timeout: .seconds(2)
      )
      let readyEvents = try readyEvents(from: events)
      guard
        readyEvents.contains(.diagnosticReadable)
          || readyEvents.contains(.diagnosticHangup)
      else {
        throw TestFailure("Diagnostic did not become readable: \(events)")
      }
      let result = try buffer.withUnsafeMutableBytes { bytes in
        try MojoPOSIXWorkerSupport.read(
          descriptor: descriptor,
          into: bytes
        )
      }
      switch result {
      case .bytes(let count):
        data.append(buffer, count: count)
      case .eof:
        return data
      case .interrupted, .wouldBlock:
        continue
      }
    }
  }

  private func drainAvailable(descriptor: Int32) throws -> Int {
    var count = 0
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let result = try buffer.withUnsafeMutableBytes { bytes in
        try MojoPOSIXWorkerSupport.read(
          descriptor: descriptor,
          into: bytes
        )
      }
      switch result {
      case .bytes(let readCount):
        count += readCount
      case .eof, .wouldBlock:
        return count
      case .interrupted:
        continue
      }
    }
  }

  private func writeAll(descriptor: Int32, data: Data) throws -> Int {
    var offset = 0
    while offset < data.count {
      let events = try MojoPOSIXWorkerSupport.poll(
        protocolDescriptor: descriptor,
        diagnosticDescriptor: -1,
        interests: [.write],
        timeout: .seconds(2)
      )
      let readyEvents = try readyEvents(from: events)
      guard readyEvents.contains(.protocolWritable) else {
        throw TestFailure("Protocol did not become writable: \(events)")
      }
      let result = try data.withUnsafeBytes { bytes in
        let remaining = data.count - offset
        let start = bytes.baseAddress!.advanced(by: offset)
        return try MojoPOSIXWorkerSupport.write(
          descriptor: descriptor,
          from: UnsafeRawBufferPointer(
            start: start,
            count: remaining
          )
        )
      }
      switch result {
      case .bytes(let count):
        offset += count
      case .interrupted, .wouldBlock:
        continue
      case .eof:
        throw TestFailure("Unexpected protocol EOF while writing")
      }
    }
    return offset
  }

  private func waitForReap(
    _ processID: MojoPOSIXSupport.ProcessID,
    timeout: Duration = .seconds(5)
  ) throws -> Int32 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if let status = try MojoPOSIXSupport.waitNoHang(processID: processID) {
        return status
      }
      Thread.sleep(forTimeInterval: 0.01)
    }
    if let status = try MojoPOSIXSupport.waitNoHang(processID: processID) {
      return status
    }
    throw TestFailure(
      "Worker was not reaped before the test deadline "
        + "processAlive=\(MojoPOSIXSupport.processIsAlive(processID)) "
        + "groupAlive=\(MojoPOSIXSupport.processGroupIsAlive(processID))"
    )
  }

  private func readyEvents(
    from result: MojoPOSIXWorkerPollResult
  ) throws -> MojoPOSIXWorkerPollEvents {
    guard case .ready(let events) = result else {
      throw TestFailure("Worker poll did not produce readiness: \(result)")
    }
    return events
  }
}

private struct TestFailure: Error, CustomStringConvertible {
  let message: String

  init(_ message: String) {
    self.message = message
  }

  var description: String { message }
}
