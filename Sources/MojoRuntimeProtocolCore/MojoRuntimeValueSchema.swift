import Crypto
import Foundation

/// One scalar-layout identity used by binding generation and invocation admission.
package enum MojoRuntimeValueSchema {
    package static func digest(_ types: [MojoRuntimeElementType]) throws -> [UInt8] {
        guard types.count <= Int(UInt16.max) else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        var data = Data("swift-mojo-values".utf8)
        var count = UInt16(types.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        for type in types {
            var identifier = type.rawValue.littleEndian
            withUnsafeBytes(of: &identifier) { data.append(contentsOf: $0) }
        }
        return Array(SHA256.hash(data: data))
    }
}
