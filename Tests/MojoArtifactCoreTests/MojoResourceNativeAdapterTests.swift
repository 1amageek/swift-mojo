import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoRuntimeProtocolCore
import Testing

@Suite("Generated resource native adapter")
struct MojoResourceNativeAdapterTests {
    @Test(.timeLimit(.minutes(1)))
    func generatedEntryPreservesTypedInputsAndPackedScalars() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Fixture cleanup failed: \(error)") }
        }
        let types = MojoRuntimeElementType.allCases
        let names = types.map { ".\($0.sourceName)" }.joined(separator: ", ")
        let source = """
        @mojo(package: "Numeric", function: "create", shutdown: "destroy")
        func open(_ requirements: MojoSessionRequirements) throws -> MojoSessionOwner
        @mojo(package: "Numeric", function: "compute", sessionFactory: "open",
              argumentTypes: [\(names)], inputTypes: [.uint16], inputRanks: [2],
              resultTypes: [\(names)], outputTypes: [.float32])
        func compute(_ worker: MojoRuntimeWorker) throws -> MojoRuntimeWorkerOperation
        """
        let url = root.appendingPathComponent("Bindings.swift")
        try source.write(to: url, atomically: false, encoding: .utf8)
        let graph = MojoInputGraph(bindingGraph: try MojoSourceGraph(sourceURLs: [url]))
        let identity = try MojoArtifactIdentity(targetName: "ResourceProof")
        let renderer = MojoStaticSourceRenderer()
        let rendered = renderer.render(inputGraph: graph, identity: identity)
        let header = renderer.header(identity: identity, inputGraph: graph)
        let binding = try #require(graph.bindingGraph.bindings.first { $0.signature == .resourceInvocation })
        let symbol = "\(identity.symbolPrefix)_invoke_resource_\(binding.bindingID)"
        #expect(renderer.exportedSymbols(identity: identity, inputGraph: graph).contains(symbol))
        #expect(header.contains("const uint16_t *input_0"))
        #expect(rendered.source.contains("input_0: Pointer[UInt16, ImmUntrackedOrigin]"))
        #expect(rendered.source.contains("if count_0[] > capacity_0:"))
        #expect(rendered.source.contains("return status"))
        #expect(!rendered.source.contains("malloc"))
        // The optional directory is an explicit native qualification output,
        // consumed by scripts/resource-native-adapter-test.sh on Mac or Linux.
        if let path = ProcessInfo.processInfo.environment["SWIFT_MOJO_RESOURCE_PROOF_DIRECTORY"] {
            let output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try rendered.source.write(to: output.appendingPathComponent("bridge.mojo"), atomically: false, encoding: .utf8)
            try header.write(to: output.appendingPathComponent("bridge.h"), atomically: false, encoding: .utf8)
            try symbol.write(to: output.appendingPathComponent("symbol"), atomically: false, encoding: .utf8)
        }
    }
}
