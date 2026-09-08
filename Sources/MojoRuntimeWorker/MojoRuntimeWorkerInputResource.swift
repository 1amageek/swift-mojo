import Foundation

/// The exact identity of one immutable input file admitted for a worker attempt.
public struct MojoRuntimeWorkerInputResource: Sendable {
    public let identifier: MojoRuntimeWorkerInputResourceID
    package let fileURL: URL
    public let expectedByteCount: Int64
    public let expectedSHA256: String

    public init(
        identifier: MojoRuntimeWorkerInputResourceID,
        fileURL: URL,
        expectedByteCount: Int64,
        expectedSHA256: String
    ) throws {
        guard fileURL.isFileURL,
              !fileURL.path.utf8.contains(0),
              expectedByteCount > 0,
              expectedSHA256.utf8.count == 64,
              expectedSHA256.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            throw MojoRuntimeWorkerError.invalidInputResourceIdentity
        }
        self.identifier = identifier
        self.fileURL = fileURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
    }
}
