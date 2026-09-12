import Foundation
import MojoPOSIXSupport
import MojoRuntimeProtocolCore
public import MojoRuntimeWorker

public enum MojoPOSIXInputError: Error, Equatable, Sendable {
  case nativeFailure(operation: String, code: Int32, cleanupCode: Int32)
  case admissionFailure(String)
  case cleanupFailure(primary: String, cleanup: String)
}

public enum MojoPOSIXSharedInputKind: Sendable {
  case regularFile
  case dmaBuf

  var storageKind: MojoRuntimeBufferStorageKind {
    switch self {
    case .regularFile: .sharedFile
    case .dmaBuf: .dmaBuf
    }
  }
}

/// Platform ingress only. The producer must guarantee immutable contents and
/// fixed allocation size until its retained read lease is released.
public enum MojoPOSIXSharedInput {
  public static func importReadOnly(
    descriptor: Int32, byteCount: Int,
    retaining producer: any AnyObject & Sendable,
    kind: MojoPOSIXSharedInputKind
  ) throws(MojoPOSIXInputError) -> MojoReadOnlyBuffer {
    let duplicate: Int32
    do {
      duplicate = try MojoPOSIXSharedInputSupport.duplicate(
        descriptor: descriptor, kind: kind.storageKind.rawValue, byteCount: byteCount
      )
    } catch {
      throw projected(error)
    }
    let file = FileHandle(fileDescriptor: duplicate, closeOnDealloc: true)
    do {
      return try MojoReadOnlyBuffer(
        sharedDescriptor: duplicate, kind: kind.storageKind, byteCount: byteCount,
        owner: NativeStorage(file: file, producer: producer)
      )
    } catch {
      do { try file.close() }
      catch let cleanup {
        throw .cleanupFailure(primary: String(describing: error), cleanup: String(describing: cleanup))
      }
      throw projected(error)
    }
  }

  private static func projected(_ error: any Error) -> MojoPOSIXInputError {
    if let error = error as? MojoPOSIXInputError { return error }
    if let error = error as? MojoPOSIXSharedInputError {
      switch error {
      case .invalidExtent: return .admissionFailure("Byte count must be positive")
      case .operationFailed(let operation, let code, let cleanup):
        return .nativeFailure(operation: operation, code: code, cleanupCode: cleanup)
      }
    }
    return .admissionFailure(String(describing: error))
  }
}

/// Immutable ownership only. The private FileHandle is never read, mutated or
/// exposed; its standard RAII lifetime closes the sole duplicate exactly once.
private final class NativeStorage: Sendable {
  let file: FileHandle
  let producer: any AnyObject & Sendable

  init(file: FileHandle, producer: any AnyObject & Sendable) {
    self.file = file
    self.producer = producer
  }
}
