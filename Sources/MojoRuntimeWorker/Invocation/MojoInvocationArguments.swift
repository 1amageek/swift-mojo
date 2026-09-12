import Foundation
import MojoRuntimeProtocolCore

/// Ordered scalar arguments, encoded only after the verified binding admits them.
public struct MojoInvocationArguments: Sendable {
    private let values: [MojoInvocationValue]
    package let schema: [UInt8]
    package let byteCount: Int

    public init(_ values: [MojoInvocationValue]) throws {
        guard values.count <= Int(UInt16.max) else {
            throw MojoInvocationArgumentError.tooManyValues
        }
        self.values = values
        self.schema = try MojoRuntimeValueSchema.digest(values.map(\.type))
        // At most UInt16.max values of eight bytes; the sum fits every supported Int.
        self.byteCount = values.reduce(0) { $0 + Int($1.type.byteWidth) }
    }

    package func encoded(expectedSchema: [UInt8], maximumBytes: UInt32) throws -> Data {
        guard schema == expectedSchema else {
            throw MojoInvocationArgumentError.schemaMismatch
        }
        guard byteCount <= maximumBytes else {
            throw MojoInvocationArgumentError.byteLimitExceeded
        }
        var data = Data()
        data.reserveCapacity(byteCount)
        for value in values { value.append(to: &data) }
        return data
    }
}
