import Foundation
import MojoArtifactCore
import MojoBindingCore
import Testing

@Suite("Mojo exported symbols")
struct MojoExportedSymbolsTests {
    @Test(.timeLimit(.minutes(1)))
    func derivesTheExactRenderedABIFromTheInputGraph() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-exported-symbols-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove exported-symbol fixture: \(error)")
            }
        }
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        try source.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let inputGraph = MojoInputGraph(
            bindingGraph: try MojoSourceGraph(sourceURLs: [sourceURL])
        )
        let identity = try MojoArtifactIdentity(targetName: "AllBindings")
        let renderer = MojoStaticSourceRenderer()
        let rendered = renderer.render(
            inputGraph: inputGraph,
            identity: identity
        ).source
        let renderedExports = Set(rendered.split(separator: "\n").compactMap {
            exportedSymbol(from: $0)
        })
        let expected = Set([
            "static_abi_version",
            "input_graph_identifier",
            "has_binding",
            "call_i32_i32_i32",
            "call_f32_buffer_f32",
            "call_f32_buffer_f32_buffer_i32",
            "call_f64_buffer_f64_buffer_i32",
            "create_session_v1",
            "shutdown_session_v1",
            "create_f32_buffer_v1",
            "shutdown_f32_buffer_v1",
            "copy_host_to_f32_buffer_v1",
            "copy_f32_buffer_to_host_v1",
            "call_session_f32_buffer_f32_buffer_i32_v1",
        ].map { "\(identity.symbolPrefix)_\($0)" })

        #expect(renderedExports == expected)
        #expect(
            renderer.exportedSymbols(
                identity: identity,
                inputGraph: inputGraph
            ) == renderedExports
        )
    }

    private var source: String {
        """
        @mojo
        func add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
            return lhs + rhs
        }

        @mojo(package: "Fixture", function: "sum")
        func sum(_ values: [Float]) throws -> Float

        @mojo(package: "Fixture", function: "scale_float")
        func scaleFloat(_ input: [Float], into output: inout [Float]) throws

        @mojo(package: "Fixture", function: "scale_double")
        func scaleDouble(_ input: [Double], into output: inout [Double]) throws

        @mojo(
            package: "Fixture",
            function: "create_session",
            shutdown: "shutdown_session"
        )
        func openSession(
            _ requirements: MojoSessionRequirements
        ) throws -> MojoSessionOwner

        @mojo(
            package: "Fixture",
            function: "create_buffer",
            shutdown: "shutdown_buffer",
            copyFromHost: "copy_from_host",
            copyToHost: "copy_to_host",
            synchronize: "synchronize",
            sessionFactory: "openSession"
        )
        func makeBuffer(
            _ session: MojoSessionOwner,
            elementCount: UInt64,
            memoryKind: MojoBufferMemoryKind
        ) throws -> MojoFloat32BufferOwner

        @mojo(
            package: "Fixture",
            function: "execute",
            sessionFactory: "openSession"
        )
        func execute(
            _ session: MojoSessionOwner,
            _ input: [Float],
            into output: inout [Float]
        ) throws
        """
    }

    private func exportedSymbol(from line: Substring) -> String? {
        let prefix = "@export(\""
        let suffix = "\")"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            return nil
        }
        return String(
            line.dropFirst(prefix.count).dropLast(suffix.count)
        )
    }
}
