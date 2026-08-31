import Foundation

public struct RuntimeWorkerAcceptanceRunConfiguration: Equatable, Sendable {
    public let bundleURL: URL
    public let failureBundleURL: URL
    public let consumerExecutableURL: URL
    public let temporaryDirectoryURL: URL
    public let repositoryRootURL: URL
    public let expectedSourceDigest: String
    public let swiftMojoRevision: String
    public let consumerDeadline: Duration

    public init(
        bundleURL: URL,
        failureBundleURL: URL? = nil,
        consumerExecutableURL: URL,
        temporaryDirectoryURL: URL,
        repositoryRootURL: URL,
        expectedSourceDigest: String,
        swiftMojoRevision: String,
        consumerDeadline: Duration = .seconds(45)
    ) throws {
        guard consumerDeadline > .zero else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "consumer deadline must be positive"
            )
        }
        guard expectedSourceDigest.utf8.count == 64,
            expectedSourceDigest.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            })
        else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "expected source digest must be lowercase SHA-256"
            )
        }
        guard swiftMojoRevision.utf8.count == 40,
            swiftMojoRevision.utf8.allSatisfy({ byte in
                (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
            })
        else {
            throw RuntimeWorkerAcceptanceRunnerError.invalidInput(
                "swift-mojo revision must be a lowercase 40-character Git object ID"
            )
        }
        self.bundleURL = bundleURL.standardizedFileURL
        self.failureBundleURL = (failureBundleURL ?? bundleURL).standardizedFileURL
        self.consumerExecutableURL = consumerExecutableURL.standardizedFileURL
        self.temporaryDirectoryURL = temporaryDirectoryURL.standardizedFileURL
        self.repositoryRootURL = repositoryRootURL.standardizedFileURL
        self.expectedSourceDigest = expectedSourceDigest
        self.swiftMojoRevision = swiftMojoRevision
        self.consumerDeadline = consumerDeadline
    }
}
