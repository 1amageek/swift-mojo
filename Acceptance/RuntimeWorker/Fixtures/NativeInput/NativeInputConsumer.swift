import Foundation
import MojoPOSIXSupport
import MojoRuntimeWorker
import MojoRuntimeWorkerPOSIX
import Synchronization

private final class ReleaseCounter: Sendable {
  let value = Mutex(0)
}

private final class ProducerLease: Sendable {
  let file: FileHandle
  let counter: ReleaseCounter
  init(descriptor: Int32, counter: ReleaseCounter) {
    file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    self.counter = counter
  }
  deinit { counter.value.withLock { $0 += 1 } }
}

@main
struct NativeInputConsumer {
  static func main() throws {
    guard CommandLine.arguments.count == 3,
      let descriptor = Int32(CommandLine.arguments[1]),
      let extent = Int(CommandLine.arguments[2]), extent >= 8
    else { throw ProbeError.invalidArguments }
    let counter = ReleaseCounter()
    var buffer: MojoReadOnlyBuffer? = try input(descriptor: descriptor, extent: extent, counter: counter)
    try withExtendedLifetime(buffer) {
      guard counter.value.withLock({ $0 }) == 0,
        let buffer, case .shared(let fd, _, _) = buffer.storage
      else { throw ProbeError.ownership }
      let mapping = try MojoPOSIXSharedInputSupport.map(descriptor: fd, byteCount: extent)
      guard try MojoPOSIXSharedInputSupport.synchronize(descriptor: fd, ending: false) == .completed
      else { throw ProbeError.synchronization }
      let actual = mapping.loadUnaligned(as: UInt64.self)
      guard try MojoPOSIXSharedInputSupport.synchronize(descriptor: fd, ending: true) == .completed
      else { throw ProbeError.synchronization }
      try MojoPOSIXSharedInputSupport.unmap(mapping)
      guard actual == 0x3141592653589793 else { throw ProbeError.wrongBytes }
    }
    buffer = nil
    guard counter.value.withLock({ $0 }) == 1 else { throw ProbeError.ownership }
    print("PASS: public DMA-BUF admission, readonly shared marker, START/END, unmap and producer release; bytes=\(extent)")
  }
  private static func input(descriptor: Int32, extent: Int, counter: ReleaseCounter) throws -> MojoReadOnlyBuffer {
    let producer = ProducerLease(descriptor: descriptor, counter: counter)
    return try MojoPOSIXSharedInput.importReadOnly(
      descriptor: descriptor, byteCount: extent, retaining: producer, kind: .dmaBuf
    )
  }
}

private enum ProbeError: Error {
  case invalidArguments
  case ownership
  case synchronization
  case wrongBytes
}
