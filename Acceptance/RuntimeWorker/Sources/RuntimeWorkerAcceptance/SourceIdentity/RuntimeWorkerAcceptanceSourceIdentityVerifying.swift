import Foundation

public protocol RuntimeWorkerAcceptanceSourceIdentityVerifying: Sendable {
    func sourceIdentity(
        at repositoryRoot: URL
    ) throws -> RuntimeWorkerAcceptanceSourceIdentity
}
