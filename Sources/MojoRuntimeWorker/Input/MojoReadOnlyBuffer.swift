import MojoRuntimeProtocolCore

public enum MojoBufferError: Error, Equatable, Sendable {
  case invalidByteCount
}

/// Retains immutable input storage. Native sharing is granted only by an importer.
public final class MojoReadOnlyBuffer: Sendable {
  public let byteCount: Int
  package let storage: Storage

  package enum Storage: Sendable {
    case host(any MojoBufferSource)
    case shared(descriptor: Int32, kind: MojoRuntimeBufferStorageKind, owner: any AnyObject & Sendable)
  }

  /// Selects host storage for explicit copied transport; no copy occurs here.
  public init(hostSource: any MojoBufferSource) throws(MojoBufferError) {
    let byteCount = hostSource.byteCount
    guard byteCount >= 0 else { throw .invalidByteCount }
    self.byteCount = byteCount
    self.storage = .host(hostSource)
  }

  package init(
    sharedDescriptor: Int32, kind: MojoRuntimeBufferStorageKind,
    byteCount: Int, owner: any AnyObject & Sendable
  ) throws(MojoBufferError) {
    guard byteCount > 0, sharedDescriptor >= 0, kind != .copied else {
      throw .invalidByteCount
    }
    self.byteCount = byteCount
    self.storage = .shared(descriptor: sharedDescriptor, kind: kind, owner: owner)
  }
}
