import Crypto
import Foundation

package enum MojoCanonicalDigestError: Error, Equatable, CustomStringConvertible {
  case symbolicLink(String)
  case symbolicLinkDestination(path: String, expected: String, actual: String)
  case symbolicLinkEscapesRoot(String)
  case symbolicLinkMissing(String)

  package var description: String {
    switch self {
    case .symbolicLink(let path):
      "Canonical trees cannot contain symbolic links: '\(path)'"
    case .symbolicLinkDestination(let path, let expected, let actual):
      "Canonical tree symbolic link '\(path)' targets '\(actual)' instead of '\(expected)'"
    case .symbolicLinkEscapesRoot(let path):
      "Canonical tree symbolic link escapes its root: '\(path)'"
    case .symbolicLinkMissing(let path):
      "Canonical tree expected a symbolic link at '\(path)'"
    }
  }
}

package enum MojoCanonicalDigest {
  package static func hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8))
      .map { String(format: "%02x", $0) }
      .joined()
  }

  package static func hex(_ data: Data) -> String {
    digestHex(data)
  }

  package static func identifier(_ value: String) -> UInt64 {
    let identifier = SHA256.hash(data: Data(value.utf8))
      .prefix(MemoryLayout<UInt64>.size)
      .reduce(UInt64.zero) { partial, byte in
        (partial << 8) | UInt64(byte)
      }
    return identifier & 0x7fff_ffff_ffff_ffff
  }

  package static func file(at url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return digestHex(data)
  }

  package static func tree(
    at rootURL: URL,
    allowedSymbolicLinks: [String: String] = [:]
  ) throws -> String {
    let fileManager = FileManager.default
    let canonicalRoot = rootURL.standardizedFileURL
    let rootAttributes = try fileManager.attributesOfItem(
      atPath: rootURL.path
    )
    guard
      rootAttributes[.type] as? FileAttributeType
        != .typeSymbolicLink
    else {
      throw MojoCanonicalDigestError.symbolicLink(rootURL.path)
    }
    var entries: [(path: String, symbolicLinkDestination: String?)] = []
    let rootPath =
      canonicalRoot.path.hasSuffix("/")
      ? canonicalRoot.path
      : canonicalRoot.path + "/"
    var observedSymbolicLinks = Set<String>()

    func appendEntries(in directoryURL: URL, relativeDirectory: String) throws {
      let names = try fileManager.contentsOfDirectory(atPath: directoryURL.path)
      for name in names {
        let relativePath =
          relativeDirectory.isEmpty
          ? name
          : "\(relativeDirectory)/\(name)"
        let url = directoryURL.appendingPathComponent(name)
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        switch type {
        case .typeSymbolicLink:
          guard let expected = allowedSymbolicLinks[relativePath] else {
            throw MojoCanonicalDigestError.symbolicLink(url.path)
          }
          let actual = try fileManager.destinationOfSymbolicLink(atPath: url.path)
          guard actual == expected else {
            throw MojoCanonicalDigestError.symbolicLinkDestination(
              path: url.path,
              expected: expected,
              actual: actual
            )
          }
          guard !NSString(string: actual).isAbsolutePath else {
            throw MojoCanonicalDigestError.symbolicLinkEscapesRoot(url.path)
          }
          let resolvedTarget = url.deletingLastPathComponent()
            .appendingPathComponent(actual)
            .standardizedFileURL
          guard resolvedTarget.path.hasPrefix(rootPath),
            fileManager.fileExists(atPath: resolvedTarget.path)
          else {
            throw MojoCanonicalDigestError.symbolicLinkEscapesRoot(url.path)
          }
          observedSymbolicLinks.insert(relativePath)
          entries.append((relativePath, actual))
        case .typeDirectory:
          try appendEntries(in: url, relativeDirectory: relativePath)
        case .typeRegular:
          entries.append((relativePath, nil))
        default:
          continue
        }
      }
    }

    try appendEntries(in: rootURL, relativeDirectory: "")
    for relativePath in allowedSymbolicLinks.keys
    where !observedSymbolicLinks.contains(relativePath) {
      throw MojoCanonicalDigestError.symbolicLinkMissing(relativePath)
    }
    entries.sort { $0.path < $1.path }

    var hasher = SHA256()
    for entry in entries {
      let pathData: Data
      let contents: Data
      if let destination = entry.symbolicLinkDestination {
        pathData = Data("\0symlink:\(entry.path)".utf8)
        contents = Data(destination.utf8)
      } else {
        pathData = Data(entry.path.utf8)
        contents = try Data(
          contentsOf: rootURL.appendingPathComponent(entry.path),
          options: .mappedIfSafe
        )
      }
      hasher.update(data: lengthBytes(pathData.count))
      hasher.update(data: pathData)
      hasher.update(data: lengthBytes(contents.count))
      hasher.update(data: contents)
    }
    return hasher.finalize()
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func digestHex(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func lengthBytes(_ count: Int) -> Data {
    let value = UInt64(count)
    return Data(
      (0..<MemoryLayout<UInt64>.size).reversed().map { index in
        UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
      })
  }
}
