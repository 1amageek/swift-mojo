import CryptoKit
import Foundation

package enum MojoCanonicalDigest {
    package static func hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
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
        guard let enumerator = fileManager.enumerator(atPath: rootURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        var relativePaths: [String] = []
        for case let relativePath as String in enumerator {
            guard !relativePath.split(separator: "/").contains(where: {
                $0.hasPrefix(".")
            }) else {
                continue
            }
            let url = rootURL.appendingPathComponent(relativePath)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
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
