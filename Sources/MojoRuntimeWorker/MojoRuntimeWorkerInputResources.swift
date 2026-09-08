import Crypto
import Foundation

/// A bounded immutable set of input resources for one worker attempt.
public struct MojoRuntimeWorkerInputResources: Sendable {
    public static let directoryEnvironmentKey =
        "SWIFT_MOJO_INPUT_RESOURCE_DIRECTORY"
    public static let countEnvironmentKey = "SWIFT_MOJO_INPUT_RESOURCE_COUNT"
    public static let bytesEnvironmentKey = "SWIFT_MOJO_INPUT_RESOURCE_BYTES"
    public static let sha256EnvironmentKey =
        "SWIFT_MOJO_INPUT_RESOURCE_SHA256"
    public static let runtimeLibraryDirectoryEnvironmentKey =
        "SWIFT_MOJO_RUNTIME_LIBRARY_DIRECTORY"

    public let count: Int
    public let aggregateByteCount: Int64
    public let aggregateSHA256: String

    package let values: [MojoRuntimeWorkerInputResource]

    public init(
        resources: [MojoRuntimeWorkerInputResource],
        limits: MojoRuntimeWorkerInputResourceLimits
    ) throws {
        guard !resources.isEmpty else {
            throw MojoRuntimeWorkerError.emptyInputResources
        }
        guard resources.count <= limits.maximumResourceCount else {
            throw MojoRuntimeWorkerError.inputResourceCountLimitExceeded
        }

        var identifiers = Set<MojoRuntimeWorkerInputResourceID>()
        var aggregateByteCount: Int64 = 0
        for resource in resources {
            guard identifiers.insert(resource.identifier).inserted else {
                throw MojoRuntimeWorkerError.duplicateInputResourceIdentifier
            }
            guard resource.expectedByteCount <=
                    limits.maximumAggregateByteCount - aggregateByteCount else {
                throw MojoRuntimeWorkerError
                    .inputResourceAggregateByteCountLimitExceeded
            }
            aggregateByteCount += resource.expectedByteCount
        }

        let sorted = resources.sorted {
            $0.identifier.rawValue < $1.identifier.rawValue
        }
        self.values = sorted
        self.count = sorted.count
        self.aggregateByteCount = aggregateByteCount
        self.aggregateSHA256 = Self.aggregateSHA256(for: sorted)
    }

    package static let directoryName = "input-resources"

    private static func aggregateSHA256(
        for resources: [MojoRuntimeWorkerInputResource]
    ) -> String {
        var descriptor = Data()
        for resource in resources {
            let identifierBytes = Array(resource.identifier.rawValue.utf8)
            var identifierByteCount = UInt32(identifierBytes.count).littleEndian
            withUnsafeBytes(of: &identifierByteCount) {
                descriptor.append(contentsOf: $0)
            }
            descriptor.append(contentsOf: identifierBytes)

            var byteCount = UInt64(resource.expectedByteCount).littleEndian
            withUnsafeBytes(of: &byteCount) {
                descriptor.append(contentsOf: $0)
            }
            descriptor.append(contentsOf: digestBytes(resource.expectedSHA256))
        }

        var digest = SHA256()
        digest.update(data: descriptor)
        return digest.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digestBytes(_ value: String) -> [UInt8] {
        let bytes = Array(value.utf8)
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count / 2)
        var index = 0
        while index < bytes.count {
            result.append((nibble(bytes[index]) << 4) | nibble(bytes[index + 1]))
            index += 2
        }
        return result
    }

    private static func nibble(_ byte: UInt8) -> UInt8 {
        switch byte {
        case 48...57:
            return byte - 48
        case 97...102:
            return byte - 87
        default:
            preconditionFailure("Input resource digest is not lowercase hex")
        }
    }
}
