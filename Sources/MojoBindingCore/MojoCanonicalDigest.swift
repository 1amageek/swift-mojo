import CryptoKit
import Foundation

package enum MojoCanonicalDigestError: Error, Equatable, CustomStringConvertible {
    case symbolicLink(String)

    package var description: String {
        switch self {
        case .symbolicLink(let path):
            "Canonical trees cannot contain symbolic links: '\(path)'"
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

    package static func tree(at rootURL: URL) throws -> String {
        let fileManager = FileManager.default
        let rootValues = try rootURL.resourceValues(
            forKeys: [.isSymbolicLinkKey]
        )
        guard rootValues.isSymbolicLink != true else {
            throw MojoCanonicalDigestError.symbolicLink(rootURL.path)
        }
        guard let enumerator = fileManager.enumerator(atPath: rootURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var relativePaths: [String] = []
        for case let relativePath as String in enumerator {
            let url = rootURL.appendingPathComponent(relativePath)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isSymbolicLink != true else {
                throw MojoCanonicalDigestError.symbolicLink(url.path)
            }
            if values.isRegularFile == true {
                relativePaths.append(relativePath)
            }
        }
        relativePaths.sort()

        var hasher = SHA256()
        for relativePath in relativePaths {
            let fileURL = rootURL.appendingPathComponent(relativePath)
            let pathData = Data(relativePath.utf8)
            let contents = try Data(
                contentsOf: fileURL,
                options: .mappedIfSafe
            )
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
        return Data((0..<MemoryLayout<UInt64>.size).reversed().map { index in
            UInt8(truncatingIfNeeded: value >> UInt64(index * 8))
        })
    }
}
