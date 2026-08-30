import Foundation

package enum MojoRuntimeProtocolError: Error, Equatable, Sendable,
    CustomStringConvertible
{
    case invalidMagic(actual: [UInt8])
    case invalidVersion(expected: UInt16, actual: UInt16)
    case unknownKind(UInt16)
    case reservedFieldNonZero(UInt64)
    case invalidRequestIdentifier(kind: UInt16, requestID: UInt64)
    case invalidPayloadLength
    case payloadTooLarge(length: UInt64, limit: UInt64)
    case integerOverflow(operation: String)
    case schemaMismatch(expected: UInt32, actual: UInt32)
    case truncatedHeader(actual: Int)
    case truncatedPayload(expected: Int, actual: Int)
    case trailingBytes(Int)
    case invalidPayload(kind: MojoRuntimeFrameKind, reason: String)
    case invalidUTF8
    case invalidDigest(String)
    case invalidLimit
    case sequenceViolation(String)
    case responseIdentifierMismatch(expected: UInt64, actual: UInt64)
    case responseKindMismatch(
        expected: MojoRuntimeFrameKind,
        actual: MojoRuntimeFrameKind
    )
    case secondInFlight
    case tensorBodyRequiresBorrowedSegment
    case unexpectedFrame(
        expected: MojoRuntimeFrameKind,
        actual: MojoRuntimeFrameKind
    )

    package var description: String {
        switch self {
        case .invalidMagic(let actual):
            "Protocol magic is invalid: \(actual)"
        case .invalidVersion(let expected, let actual):
            "Protocol version is \(actual), expected \(expected)"
        case .unknownKind(let rawValue):
            "Protocol message kind \(rawValue) is not part of the closed table"
        case .reservedFieldNonZero(let value):
            "Protocol reserved header field is \(value), expected zero"
        case .invalidRequestIdentifier(let kind, let requestID):
            "Protocol request identifier \(requestID) is invalid for kind \(kind)"
        case .invalidPayloadLength:
            "Protocol payload length cannot be represented"
        case .payloadTooLarge(let length, let limit):
            "Protocol payload length \(length) exceeds limit \(limit)"
        case .integerOverflow(let operation):
            "Protocol integer overflow during \(operation)"
        case .schemaMismatch(let expected, let actual):
            "Protocol schema \(actual) is unsupported; expected \(expected)"
        case .truncatedHeader(let actual):
            "Protocol header is truncated: found \(actual) bytes"
        case .truncatedPayload(let expected, let actual):
            "Protocol payload is truncated: expected \(expected) bytes, found \(actual)"
        case .trailingBytes(let count):
            "Protocol frame has \(count) trailing bytes"
        case .invalidPayload(let kind, let reason):
            "Payload for \(kind) is invalid: \(reason)"
        case .invalidUTF8:
            "Protocol text field is not valid UTF-8"
        case .invalidDigest(let value):
            "Protocol digest is not a lowercase SHA-256 hex value: \(value)"
        case .invalidLimit:
            "Protocol payload limit must be positive and within the hard ceiling"
        case .sequenceViolation(let reason):
            "Protocol sequence is invalid: \(reason)"
        case .responseIdentifierMismatch(let expected, let actual):
            "Protocol response identifier is \(actual), expected \(expected)"
        case .responseKindMismatch(let expected, let actual):
            "Protocol response kind is \(actual), expected \(expected)"
        case .secondInFlight:
            "Protocol v1 permits only one in-flight request"
        case .tensorBodyRequiresBorrowedSegment:
            "Float32 tensor bodies are borrowed segments and cannot be materialized by the frame codec"
        case .unexpectedFrame(let expected, let actual):
            "Protocol frame is \(actual), expected \(expected)"
        }
    }
}
