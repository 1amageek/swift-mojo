import Foundation

public enum RuntimeWorkerAcceptanceSourceIdentityError:
    Error,
    Equatable,
    CustomStringConvertible,
    Sendable
{
    case invalidRoot(String)
    case invalidPath(String)
    case missingEntry(String)
    case unexpectedEntry(String)
    case symbolicLink(String)
    case nonRegularEntry(String)
    case unreadableFile(path: String, detail: String)
    case fileTooLarge(path: String, maximumByteCount: Int)
    case totalTooLarge(maximumByteCount: Int)
    case changedDuringRead(String)
    case closeFailed(path: String, detail: String)
    case destinationExists(String)
    case snapshotMismatch
    case snapshotMaterializationFailed(path: String, detail: String)
    case snapshotPermissionFailed(path: String, detail: String)
    case snapshotCleanupFailed(path: String, detail: String)

    public var description: String {
        switch self {
        case .invalidRoot(let path):
            "Acceptance source repository root is invalid: \(path)"
        case .invalidPath(let path):
            "Acceptance source path is not canonical: \(path)"
        case .missingEntry(let path):
            "Acceptance source inventory entry is missing: \(path)"
        case .unexpectedEntry(let path):
            "Acceptance source inventory contains an unexpected entry: \(path)"
        case .symbolicLink(let path):
            "Acceptance source inventory rejects symbolic links: \(path)"
        case .nonRegularEntry(let path):
            "Acceptance source inventory entry is not regular: \(path)"
        case .unreadableFile(let path, let detail):
            "Acceptance source file is unreadable at \(path): \(detail)"
        case .fileTooLarge(let path, let maximumByteCount):
            "Acceptance source file exceeds \(maximumByteCount) bytes: \(path)"
        case .totalTooLarge(let maximumByteCount):
            "Acceptance source inventory exceeds \(maximumByteCount) bytes"
        case .changedDuringRead(let path):
            "Acceptance source file changed while being read: \(path)"
        case .closeFailed(let path, let detail):
            "Acceptance source file close failed at \(path): \(detail)"
        case .destinationExists(let path):
            "Acceptance source snapshot destination already exists: \(path)"
        case .snapshotMismatch:
            "Acceptance source and snapshot identities do not match"
        case .snapshotMaterializationFailed(let path, let detail):
            "Acceptance source snapshot materialization failed at \(path): \(detail)"
        case .snapshotPermissionFailed(let path, let detail):
            "Acceptance source snapshot permission update failed at \(path): \(detail)"
        case .snapshotCleanupFailed(let path, let detail):
            "Acceptance source snapshot cleanup failed at \(path): \(detail)"
        }
    }
}
