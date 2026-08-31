import Foundation

public struct RuntimeWorkerAcceptanceSourceIdentity: Equatable, Sendable {
    public struct FileRecord: Equatable, Sendable {
        public let path: String
        public let byteCount: Int
        public let digest: String

    }

    public static let algorithmValue = "sha256-path-nul-bytes-nul-v1"
    public static let maximumFileByteCount = 4 * 1024 * 1024
    public static let maximumTotalByteCount = 16 * 1024 * 1024
    public static let executionScriptPath =
        "scripts/runtime-worker-acceptance.sh"

    public static let filePaths: [String] = [
        "Acceptance/RuntimeWorker/DESIGN.md",
        "Acceptance/RuntimeWorker/Fixtures/Consumer/Package.resolved",
        "Acceptance/RuntimeWorker/Fixtures/Consumer/Package.swift",
        "Acceptance/RuntimeWorker/Fixtures/Consumer/Sources/RuntimeWorkerAcceptanceConsumer/RuntimeWorkerAcceptanceConsumer.swift",
        "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Mojo/RuntimeWorkerAcceptanceModel/__init__.mojo",
        "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Package.swift",
        "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift",
        "Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/SwiftMojo.json",
        "Acceptance/RuntimeWorker/Package.resolved",
        "Acceptance/RuntimeWorker/Package.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceContract.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceController.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceError.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceProjectionOracle.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunConfiguration.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunReport.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunnerError.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/DESIGN.md",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/FileSystemRuntimeWorkerAcceptanceSourceSnapshotter.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptancePOSIX.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptanceSourceIdentity.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptanceSourceIdentityError.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptanceSourceIdentityVerifying.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptanceSourceSnapshot.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/SourceIdentity/RuntimeWorkerAcceptanceSourceSnapshotting.swift",
        "Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceRunner/RuntimeWorkerAcceptanceRunner.swift",
        "Acceptance/RuntimeWorker/Tests/RuntimeWorkerAcceptanceTests/RuntimeWorkerAcceptanceSnapshotPackageLayout.swift",
        "scripts/command-timeout.sh",
        "scripts/runtime-worker-acceptance.sh",
    ]

    public let algorithm: String
    public let inventory: [String]
    public let files: [FileRecord]
    public let totalByteCount: Int
    public let digest: String

}
