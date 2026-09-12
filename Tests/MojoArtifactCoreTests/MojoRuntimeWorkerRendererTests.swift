import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore
import Testing

@Suite("Mojo runtime worker renderer")
struct MojoRuntimeWorkerRendererTests {
    @Test(.timeLimit(.minutes(1)))
    func incompleteResourceEndpointIsNotPublishedOrAdvertisedAsCallable() throws {
        let fixture = try Fixture(includeSession: true, includeResource: true)
        #expect(throws: MojoRuntimeProtocolError.invalidPayload(
            kind: .ready, reason: "resource worker dispatch is not implemented"
        )) { try fixture.render() }
        let binding = try #require(fixture.inputGraph.bindingGraph.bindings.first {
            $0.signature == .resourceInvocation
        })
        let source = MojoStaticSourceRenderer().render(
            inputGraph: fixture.inputGraph, identity: fixture.identity
        ).source
        #expect(!source.contains("if binding_id == \(binding.bindingID):"))
    }

    @Test(.timeLimit(.minutes(1)))
    func rendersDeterministicallyFromOneInputGraph() throws {
        let fixture = try Fixture()
        let first = try fixture.render()
        let second = try fixture.render()

        #expect(first == second)
        #expect(first.executionContract.generationPipelineDigest.count == 64)
        #expect(first.executionContract.maximumFramePayloadBytes == 4096)
        #expect(first.workerSource.contains(fixture.identity.symbolPrefix))
        #expect(first.workerSource.contains("swmo_send_segments"))
        #expect(first.workerSource.contains("static const uint8_t swmo_ready_frame[]"))
        #expect(!first.workerSource.contains("uint8_t payload[4096]"))
        #expect(first.workerSource.contains("receive_storage"))
        #expect(first.workerSource.contains("send_storage"))
        #expect(first.workerSource.contains("errno == EINTR"))
        #expect(first.workerSource.contains("request_id"))
        #expect(!first.workerSource.contains("dlopen"))
        #expect(!first.workerSource.contains("dlsym"))
        #expect(!first.workerSource.contains("dlclose"))
        #expect(!first.workerSource.localizedCaseInsensitiveContains("model"))
        #expect(!first.workerSource.localizedCaseInsensitiveContains("metal"))
        #expect(!first.workerSource.localizedCaseInsensitiveContains("cuda"))
        #expect(!first.workerSource.localizedCaseInsensitiveContains("jetson"))
        #expect(!first.workerSource.localizedCaseInsensitiveContains("application"))
        #expect(first.workerSource.components(separatedBy: "malloc(").count - 1 == 2)
        #expect(!first.workerSource.contains("memcpy(result + 12u"))
        let allocation = try #require(
            first.workerSource.range(of: "uint8_t *receive_storage =")
        )
        let ready = try #require(
            first.workerSource.range(of: "if (swmo_send_ready() != 0)")
        )
        #expect(allocation.lowerBound < ready.lowerBound)
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsAStaleGeneratedMojoSourceDigestBeforeContractCreation() throws {
        let fixture = try Fixture()
        #expect(throws: MojoRuntimeProtocolError.self) {
            try fixture.render(
                generatedMojoSourceDigest: String(repeating: "c", count: 64)
            )
        }
        #expect(throws: MojoRuntimeProtocolError.self) {
            try fixture.render(maximumFramePayloadBytes: 32)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func everyPreRenderFieldMutationChangesTheContractDigest() throws {
        let fixture = try Fixture()
        let contract = try fixture.render().executionContract
        let alteredPipeline = try fixture.copy(
            contract,
            generationPipelineDigest: String(repeating: "c", count: 64)
        )
        let alteredCompiler = try fixture.copy(
            contract,
            compilerIdentity: "different-compiler"
        )
        let alteredSourceMap = try fixture.copy(
            contract,
            sourceMapDigest: String(repeating: "d", count: 64)
        )
        let alteredSource = try fixture.copy(
            contract,
            generatedMojoSourceDigest: String(repeating: "e", count: 64)
        )
        let alteredLimit = try fixture.copy(
            contract,
            maximumFramePayloadBytes: 4095
        )
        let alteredIdentifier = try fixture.copy(
            contract,
            inputGraphIdentifier: contract.inputGraphIdentifier ^ 1
        )
        let alteredGraph = try fixture.copy(
            contract,
            inputGraphDigest: String(repeating: "f", count: 64)
        )
        var bindings = contract.bindingTable.bindings
        let firstBinding = bindings.removeFirst()
        bindings.append(MojoRuntimeWorkerBinding(
            bindingID: firstBinding.bindingID ^ 1,
            functionName: firstBinding.functionName,
            signature: firstBinding.signature,
            sessionFactoryFunctionName: firstBinding.sessionFactoryFunctionName
        ))
        let alteredBinding = try fixture.copy(
            contract,
            bindingTable: MojoRuntimeWorkerBindingTable(bindings: bindings)
        )

        #expect(alteredPipeline.digest != contract.digest)
        #expect(alteredCompiler.digest != contract.digest)
        #expect(alteredSourceMap.digest != contract.digest)
        #expect(alteredSource.digest != contract.digest)
        #expect(alteredLimit.digest != contract.digest)
        #expect(alteredIdentifier.digest != contract.digest)
        #expect(alteredGraph.digest != contract.digest)
        #expect(alteredBinding.digest != contract.digest)
    }

    @Test(.timeLimit(.minutes(1)))
    func genericBindingTableKeepsDistinctSignaturesAndRejectsBrokenRelations() throws {
        let table = try MojoRuntimeWorkerBindingTable(bindings: [
            .init(
                bindingID: 1,
                functionName: "dispatch",
                signature: .borrowedFloat32Buffer
            ),
            .init(
                bindingID: 2,
                functionName: "dispatch",
                signature: .borrowedMutableFloat32Buffers
            ),
        ])
        #expect(table.bindings.count == 2)

        #expect(throws: MojoRuntimeWorkerBindingTable.ValidationError.self) {
            try MojoRuntimeWorkerBindingTable(bindings: [
                .init(
                    bindingID: 3,
                    functionName: "sessionDispatch",
                    signature: .sessionBorrowedMutableFloat32Buffers,
                    sessionFactoryFunctionName: "missingFactory"
                ),
            ])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generatedWorkerSourceCompilesAsAStandaloneCTranslationUnit() throws {
        let fixture = try Fixture(includeSession: true)
        let rendered = try fixture.render()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-worker-c-\(UUID().uuidString)",
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
                Issue.record("Failed to remove worker C fixture: \(error)")
            }
        }
        try rendered.header.write(
            to: root.appendingPathComponent("\(fixture.identity.moduleName).h"),
            atomically: true,
            encoding: .utf8
        )
        let sourceURL = root.appendingPathComponent("worker.c")
        try rendered.workerSource.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let result = try FoundationMojoProcessRunner(timeoutSeconds: 30).capture(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "clang",
                "-fsyntax-only",
                "-Werror",
                "-I",
                root.path,
                sourceURL.path,
            ]
        )
        #expect(result.status == 0, "\(result.output)")
        let factory = try #require(
            rendered.bindingTable.bindings.first {
                $0.signature == .runtimeSessionFactory
            }
        )
        #expect(rendered.workerSource.contains(
            "session_binding_id != \(factory.bindingID)ull"
        ))
    }
}

private struct Fixture {
    let inputGraph: MojoInputGraph
    let identity: MojoArtifactIdentity
    let target: MojoTargetConfiguration
    let receipt: MojoRuntimeDependencyReceipt
    let generatedMojoSourceDigest: String
    let generatedMojoObjectDigest: String

    init(includeSession: Bool = false, includeResource: Bool = false) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-worker-fixture-\(UUID().uuidString)",
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
                Issue.record("Failed to remove worker fixture: \(error)")
            }
        }
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        var sourceText: String
        if includeSession {
            sourceText = """
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
                function: "scale",
                sessionFactory: "openSession"
            )
            func scale(
                _ session: MojoSessionOwner,
                _ input: [Float],
                into output: inout [Float]
            ) throws
            """
        } else {
            sourceText = """
            @mojo(package: "Fixture", function: "sum")
            func sum(_ values: [Float]) throws -> Float
            """
        }
        if includeResource {
            sourceText += """

            @mojo(package: "Fixture", function: "resource", sessionFactory: "openSession",
                  argumentTypes: [], inputTypes: [.uint16], inputRanks: [2],
                  resultTypes: [], outputTypes: [.float32])
            func resource(_ worker: MojoRuntimeWorker) throws -> MojoRuntimeWorkerOperation
            """
        }
        try sourceText.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let sourceGraph = try MojoSourceGraph(sourceURLs: [sourceURL])
        self.inputGraph = MojoInputGraph(bindingGraph: sourceGraph)
        self.identity = try MojoArtifactIdentity(targetName: "WorkerFixture")
        self.target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )
        self.generatedMojoObjectDigest = String(repeating: "b", count: 64)
        self.receipt = MojoRuntimeDependencyReceipt(
            target: target,
            objectDigest: generatedMojoObjectDigest,
            requiredSymbols: [],
            systemDependencies: [],
            libraries: []
        )
        let renderedMojo = MojoStaticSourceRenderer().render(
            inputGraph: inputGraph,
            identity: identity
        )
        self.generatedMojoSourceDigest = MojoCanonicalDigest.hex(
            Data(renderedMojo.source.utf8)
        )
    }

    func render(
        generatedMojoSourceDigest: String? = nil,
        maximumFramePayloadBytes: UInt64 = 4096
    ) throws -> MojoRuntimeWorkerRenderedSources {
        try MojoRuntimeWorkerRenderer().render(
            inputGraph: inputGraph,
            identity: identity,
            target: target,
            compilerIdentity: "fixture-compiler",
            generatedMojoSourceDigest:
                generatedMojoSourceDigest ?? self.generatedMojoSourceDigest,
            generatedMojoObjectDigest: generatedMojoObjectDigest,
            receipt: receipt,
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
    }

    func copy(
        _ contract: MojoRuntimeWorkerExecutionContract,
        inputGraphDigest: String? = nil,
        inputGraphIdentifier: UInt64? = nil,
        bindingTable: MojoRuntimeWorkerBindingTable? = nil,
        generationPipelineDigest: String? = nil,
        compilerIdentity: String? = nil,
        sourceMapDigest: String? = nil,
        generatedMojoSourceDigest: String? = nil,
        maximumFramePayloadBytes: UInt64? = nil
    ) throws -> MojoRuntimeWorkerExecutionContract {
        try MojoRuntimeWorkerExecutionContract(
            workerABIVersion: contract.workerABIVersion,
            inputGraphDigest: inputGraphDigest ?? contract.inputGraphDigest,
            inputGraphIdentifier:
                inputGraphIdentifier ?? contract.inputGraphIdentifier,
            bindingTable: bindingTable ?? contract.bindingTable,
            target: contract.target,
            generationPipelineDigest:
                generationPipelineDigest ?? contract.generationPipelineDigest,
            compilerIdentity: compilerIdentity ?? contract.compilerIdentity,
            sourceMapDigest: sourceMapDigest ?? contract.sourceMapDigest,
            generatedMojoSourceDigest:
                generatedMojoSourceDigest ?? contract.generatedMojoSourceDigest,
            generatedMojoObjectDigest: contract.generatedMojoObjectDigest,
            maximumFramePayloadBytes:
                maximumFramePayloadBytes ?? contract.maximumFramePayloadBytes,
            receiptClosure: contract.receiptClosure
        )
    }
}
