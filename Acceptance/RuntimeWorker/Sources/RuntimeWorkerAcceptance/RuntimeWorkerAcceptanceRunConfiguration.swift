import Foundation

public struct RuntimeWorkerAcceptanceRunConfiguration: Equatable, Sendable {
    public let bundleURL: URL
    public let failureBundleURL: URL
    public let consumerExecutableURL: URL
    public let temporaryDirectoryURL: URL
    public let consumerDeadline: Duration

    public init(
        bundleURL: URL,
        failureBundleURL: URL? = nil,
        consumerExecutableURL: URL,
        temporaryDirectoryURL: URL,
        consumerDeadline: Duration = .seconds(45)
    ) throws {
        guard consumerDeadline > .zero else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "consumer deadline must be positive"
            )
        }
        self.bundleURL = bundleURL.standardizedFileURL
        self.failureBundleURL = (
            failureBundleURL ?? bundleURL
        ).standardizedFileURL
        self.consumerExecutableURL = consumerExecutableURL.standardizedFileURL
        self.temporaryDirectoryURL = temporaryDirectoryURL.standardizedFileURL
        self.consumerDeadline = consumerDeadline
    }
}
