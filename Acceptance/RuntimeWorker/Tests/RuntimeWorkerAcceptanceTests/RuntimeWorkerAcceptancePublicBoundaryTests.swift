import Foundation
import Testing

@Suite("Runtime worker acceptance public boundary")
struct RuntimeWorkerAcceptancePublicBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func consumerUsesOnlyPublicRuntimeProducts() throws {
        let sourceURL = URL(
            fileURLWithPath:
                "../../Fixtures/Consumer/Sources/RuntimeWorkerAcceptanceConsumer/RuntimeWorkerAcceptanceConsumer.swift",
            relativeTo: URL(fileURLWithPath: #filePath)
        ).standardizedFileURL
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(source.contains("import MojoRuntime\n"))
        #expect(source.contains("import MojoRuntimeWorker\n"))
        #expect(!source.contains("import MojoArtifactCore"))
        #expect(!source.contains("import MojoRuntimeProtocolCore"))
        #expect(!source.contains("import MojoPOSIXSupport"))
        #expect(!source.contains("dlopen"))
        #expect(!source.contains("dlsym"))
        #expect(!source.contains("Process("))
    }
}
