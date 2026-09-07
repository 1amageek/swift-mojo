import Foundation

/// The exact identity of one immutable input file admitted for a worker attempt.
public struct MojoRuntimeWorkerInputResource: Sendable {
    package let fileURL: URL
    package let expectedByteCount: Int64
    package let expectedSHA256: String

    public init(
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
        self.fileURL = fileURL
        self.expectedByteCount = expectedByteCount
        self.expectedSHA256 = expectedSHA256
    }
}
