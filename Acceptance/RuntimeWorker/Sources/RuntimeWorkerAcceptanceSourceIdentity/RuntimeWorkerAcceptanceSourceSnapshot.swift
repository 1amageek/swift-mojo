import Foundation

public struct RuntimeWorkerAcceptanceSourceSnapshot: Equatable, Sendable {
    public let rootURL: URL
    public let identity: RuntimeWorkerAcceptanceSourceIdentity
    public let executionScriptContents: Data
}
