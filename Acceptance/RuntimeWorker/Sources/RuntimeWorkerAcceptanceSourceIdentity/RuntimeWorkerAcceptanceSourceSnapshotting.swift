import Foundation

public protocol RuntimeWorkerAcceptanceSourceSnapshotting: Sendable {
    func materializeVerifiedSnapshot(
        from sourceRoot: URL,
        at destinationRoot: URL
    ) throws -> RuntimeWorkerAcceptanceSourceSnapshot
}
