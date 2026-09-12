import Foundation

/// Immutable host storage. Size and contents must remain stable while retained.
/// The callback borrows initialized bytes; its pointer must not escape the call.
public protocol MojoBufferSource: Sendable {
  var byteCount: Int { get }
  func withUnsafeBytes<Result>(
    _ body: (UnsafeRawBufferPointer) throws -> Result
  ) throws -> Result
}

extension Data: MojoBufferSource {
  public var byteCount: Int { count }
}
