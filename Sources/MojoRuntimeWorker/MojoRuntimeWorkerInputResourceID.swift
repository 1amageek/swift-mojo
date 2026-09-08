/// An opaque identifier used as the filename of one admitted input resource.
public struct MojoRuntimeWorkerInputResourceID: Hashable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) throws {
        let bytes = Array(rawValue.utf8)
        guard !bytes.isEmpty,
              bytes.count <= 128,
              rawValue != ".",
              rawValue != "..",
              bytes.allSatisfy(Self.isAllowedByte) else {
            throw MojoRuntimeWorkerError.invalidInputResourceIdentifier
        }
        self.rawValue = rawValue
    }

    private static func isAllowedByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 45, 46, 48...57, 65...90, 95, 97...122:
            return true
        default:
            return false
        }
    }
}
