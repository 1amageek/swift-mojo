import Crypto
import Foundation

package enum MojoRuntimeProtocol {
    package static let headerByteCount = 32
    package static let magicBytes: [UInt8] = [0x53, 0x4D, 0x57, 0x31]
    package static let maximumInFlightRequests = 1
    package static let hardMaximumFramePayloadBytes: UInt64 = 16 * 1024 * 1024

    package static let kindTable: [MojoRuntimeFrameKind] = [
        .ready,
        .createSession,
        .sessionCreated,
        .invokeFloat32,
        .invocationResult,
        .shutdownSession,
        .sessionShutdown,
        .shutdownWorker,
        .workerShutdown,
        .failure,
    ]

    package static let schemaDigest: String = {
        let records = [
            "reserved16=0;reserved64=0",
            "resource-schema=\(MojoRuntimeResourceProtocol.schemaDigest)",
            "header=\(headerByteCount)",
            "magic=SMW1",
            "max-in-flight=\(maximumInFlightRequests)",
            "hard-payload=\(hardMaximumFramePayloadBytes)",
        ] + kindTable.map { "kind=\($0.rawValue):\($0.name)" }
        var data = Data()
        for record in records {
            var length = UInt64(record.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: record.utf8)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }()

    package static func limits(maximumFramePayloadBytes: UInt64) throws
        -> MojoRuntimeProtocolLimits
    {
        try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
    }
}

package enum MojoRuntimeFrameKind: UInt16, CaseIterable, Codable, Sendable {
    case ready = 1
    case createSession = 2
    case sessionCreated = 3
    case invokeFloat32 = 4
    case invocationResult = 5
    case shutdownSession = 6
    case sessionShutdown = 7
    case shutdownWorker = 8
    case workerShutdown = 9
    case failure = 10

    package var name: String {
        switch self {
        case .ready: "ready"
        case .createSession: "createSession"
        case .sessionCreated: "sessionCreated"
        case .invokeFloat32: "invokeFloat32"
        case .invocationResult: "invocationResult"
        case .shutdownSession: "shutdownSession"
        case .sessionShutdown: "sessionShutdown"
        case .shutdownWorker: "shutdownWorker"
        case .workerShutdown: "workerShutdown"
        case .failure: "failure"
        }
    }

    package var isRequest: Bool {
        switch self {
        case .createSession, .invokeFloat32, .shutdownSession,
             .shutdownWorker:
            true
        case .ready, .sessionCreated, .invocationResult, .sessionShutdown,
             .workerShutdown, .failure:
            false
        }
    }

    package var expectedResponse: Self? {
        switch self {
        case .createSession: .sessionCreated
        case .invokeFloat32: .invocationResult
        case .shutdownSession: .sessionShutdown
        case .shutdownWorker: .workerShutdown
        case .ready, .sessionCreated, .invocationResult, .sessionShutdown,
             .workerShutdown, .failure:
            nil
        }
    }

    package var isStartup: Bool {
        self == .ready || self == .failure
    }
}

package struct MojoRuntimeProtocolLimits: Equatable, Codable, Sendable {
    package let maximumFramePayloadBytes: UInt64

    package init(maximumFramePayloadBytes: UInt64) throws {
        guard maximumFramePayloadBytes > 0,
              maximumFramePayloadBytes
                <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes else {
            throw MojoRuntimeProtocolError.invalidLimit
        }
        self.maximumFramePayloadBytes = maximumFramePayloadBytes
    }

    package func validate(payloadByteCount: UInt64) throws {
        guard payloadByteCount <= maximumFramePayloadBytes else {
            throw MojoRuntimeProtocolError.payloadTooLarge(
                length: payloadByteCount,
                limit: maximumFramePayloadBytes
            )
        }
    }
}
