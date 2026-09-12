import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

private struct WorkerBundleProcessRunner: MojoProcessRunning {
    let forbiddenExecutableImports: Bool
    let forbiddenExecutablePathPrefix: String?

    init(
        forbiddenExecutableImports: Bool = false,
        forbiddenExecutablePathPrefix: String? = nil
    ) {
        self.forbiddenExecutableImports = forbiddenExecutableImports
        self.forbiddenExecutablePathPrefix = forbiddenExecutablePathPrefix
    }

    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == "/usr/bin/nm",
              arguments.count == 2,
              arguments[0] == "-u" else {
            throw MojoArtifactError.invalidArguments(
                "Unexpected runtime worker bundle command"
            )
        }
        var symbols = [
            "_AsyncRT_DeviceContext_create",
            "_memcpy",
        ]
        if forbiddenExecutableImports,
           arguments[1].contains("/bin/"),
           forbiddenExecutablePathPrefix.map({
               arguments[1].hasPrefix($0)
           }) != false {
            symbols.append(
                contentsOf: [
                    "_dlopen@GLIBC_2.34",
                    "_dlsym@@GLIBC_2.34",
                    "_dlclose@GLIBC_2.34",
                ]
            )
        }
        return MojoProcessResult(
            status: 0,
            output: symbols.joined(separator: "\n")
        )
    }
}

private struct WorkerBundleBinaryInspector: MojoRuntimeBinaryInspecting {
    let libraries: [String: MojoRuntimeBinaryInspection]
    let executable: MojoRuntimeExecutableInspection

    func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        try MojoRegularFile.validate(at: objectURL)
    }

    func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        guard let inspection = libraries[libraryURL.lastPathComponent] else {
            throw MojoArtifactError.invalidArguments(
                "Missing runtime worker library inspection fixture"
            )
        }
        return inspection
    }

    func inspectExecutable(
        executableURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeExecutableInspection {
        try MojoRegularFile.validate(at: executableURL)
        return executable
    }
}

private struct WorkerBundleExecutableLinker: MojoRuntimeExecutableLinking {
    func link(
        objectURLs: [URL],
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String]
    ) throws {
        guard objectURLs.map(\.lastPathComponent) == [
            "Bindings.o",
            "RuntimeWorker.o",
        ] else {
            throw MojoArtifactError.invalidArguments(
                "Runtime worker executable did not receive both generated objects"
            )
        }
        var linked = Data("worker-executable-v1\n".utf8)
        for objectURL in objectURLs {
            let bytes = try Data(contentsOf: objectURL)
            var count = UInt64(bytes.count).littleEndian
            withUnsafeBytes(of: &count) { linked.append(contentsOf: $0) }
            linked.append(bytes)
        }
        try linked.write(to: outputURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: outputURL.path
        )
    }
}

@Suite("Mojo runtime worker bundles")
struct MojoRuntimeWorkerBundleTests {
    @Test(.timeLimit(.minutes(1)))
    func producesAndVerifiesAnExactTwoObjectBundle() throws {
        try withWorkerBundleFixture { fixture in
            let manifest = try fixture.prepare()
            let verified = try fixture.workerVerifier().verify(
                bundleURL: fixture.outputURL
            )
            let workerObjectDigest = try fixture.workerObjectDigest

            #expect(verified == manifest)
            #expect(
                manifest.generatedInputs.generatedMojoObjectDigest
                    == fixture.mojoObjectDigest
            )
            #expect(
                manifest.generatedInputs.generatedCWorkerObjectDigest
                    == workerObjectDigest
            )
            #expect(
                try relativeEntries(at: fixture.outputURL) == [
                    ".swift-mojo-generated",
                    "RuntimeBundle.json",
                    "RuntimeReceipt.json",
                    "RuntimeWorkerBundle.json",
                    "bin",
                    "bin/mojo-worker",
                    "lib",
                    "lib/libRuntime.dylib",
                ]
            )
            let executable = try Data(
                contentsOf: fixture.outputURL.appendingPathComponent(
                    "bin/mojo-worker"
                )
            )
            #expect(executable.contains(Data("mojo-object-v1".utf8)))
            #expect(executable.contains(Data("worker-object-v1".utf8)))
            #expect(
                Set(try relativeEntries(at: fixture.outputURL)).isDisjoint(
                    with: [
                        "Bindings.mojo",
                        "Bindings.o",
                        "RuntimeWorker.c",
                        "RuntimeWorker.o",
                        "WorkerBundleFixture.h",
                    ]
                )
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func genericRuntimeBundleVerifierRejectsTheWorkerLayout() throws {
        try withWorkerBundleFixture { fixture in
            _ = try fixture.prepare()

            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.runtimeVerifier().verify(
                    bundleURL: fixture.outputURL
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsExtraMissingAndSymbolicLinkEntries() throws {
        for mutation in WorkerBundleLayoutMutation.allCases {
            try withWorkerBundleFixture { fixture in
                _ = try fixture.prepare()
                try mutation.apply(to: fixture)

                try expectWorkerBundleRejection(
                    mutation.description,
                    verifier: fixture.workerVerifier(),
                    bundleURL: fixture.outputURL
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsManifestExecutableAndLibraryMutation() throws {
        for mutation in WorkerBundleContentMutation.allCases {
            try withWorkerBundleFixture { fixture in
                _ = try fixture.prepare()
                try mutation.apply(to: fixture)

                try expectWorkerBundleRejection(
                    mutation.description,
                    verifier: fixture.workerVerifier(),
                    bundleURL: fixture.outputURL
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsExecutionBindingProtocolAndTargetClosureDrift() throws {
        for mutation in WorkerBundleIdentityMutation.allCases {
            try withWorkerBundleFixture { fixture in
                let manifest = try fixture.prepare()
                try mutation.apply(to: fixture, manifest: manifest)

                try expectWorkerBundleRejection(
                    mutation.description,
                    verifier: fixture.workerVerifier(),
                    bundleURL: fixture.outputURL
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsEveryForbiddenDynamicLoaderImport() throws {
        try withWorkerBundleFixture { fixture in
            _ = try fixture.prepare()

            do {
                _ = try fixture.workerVerifier(
                    forbiddenExecutableImports: true
                ).verify(bundleURL: fixture.outputURL)
                Issue.record("Dynamic-loader imports unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .invalidRuntimeBundle(let detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("dlopen"))
                #expect(detail.contains("dlsym"))
                #expect(detail.contains("dlclose"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsLoaderIdentifiersInGeneratedMojoSource() throws {
        try withWorkerBundleFixture(externalFunction: "dlopen") { fixture in
            do {
                _ = try fixture.prepare()
                Issue.record(
                    "Generated Mojo loader identifier unexpectedly packaged"
                )
            } catch let error as MojoArtifactError {
                guard case .invalidRuntimeBundle(let detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("dlopen"))
            }
            #expect(
                !FileManager.default.fileExists(atPath: fixture.outputURL.path)
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsCallablePrimaryLibrariesFromTheRuntimeClosure() throws {
        try withWorkerBundleFixture(includesCallableExport: true) { fixture in
            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.prepare()
            }
        }
        try withWorkerBundleFixture(usesPrimaryLibraryName: true) { fixture in
            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.prepare()
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func freshVerificationRejectsCallableExportsInRuntimeLibraries() throws {
        try withWorkerBundleFixture { fixture in
            _ = try fixture.prepare()
            var libraries = fixture.binaryInspector.libraries
            let libraryName = fixture.libraryURL.lastPathComponent
            let inspection = try #require(libraries[libraryName])
            libraries[libraryName] = MojoRuntimeBinaryInspection(
                architecture: inspection.architecture,
                installName: inspection.installName,
                dynamicDependencies: inspection.dynamicDependencies,
                exportedSymbols: inspection.exportedSymbols.union([
                    "\(fixture.identity.symbolPrefix)_input_graph_identifier",
                ])
            )
            let inspector = WorkerBundleBinaryInspector(
                libraries: libraries,
                executable: fixture.binaryInspector.executable
            )

            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.workerVerifier(
                    binaryInspector: inspector
                ).verify(bundleURL: fixture.outputURL)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStagedVerificationPreservesThePublishedBundle() throws {
        try withWorkerBundleFixture { fixture in
            _ = try fixture.prepare()
            let beforeDigest = try MojoCanonicalDigest.tree(
                at: fixture.outputURL
            )
            let beforeContents = try regularFileContents(
                at: fixture.outputURL
            )
            let beforeEntries = try relativeEntries(at: fixture.outputURL)

            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.prepare(forbiddenExecutableImports: true)
            }

            #expect(
                try MojoCanonicalDigest.tree(at: fixture.outputURL)
                    == beforeDigest
            )
            #expect(try regularFileContents(at: fixture.outputURL) == beforeContents)
            #expect(try relativeEntries(at: fixture.outputURL) == beforeEntries)
            _ = try fixture.workerVerifier().verify(
                bundleURL: fixture.outputURL
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func failedCommittedVerificationRestoresThePublishedBundle() throws {
        try withWorkerBundleFixture { fixture in
            _ = try fixture.prepare()
            let beforeDigest = try MojoCanonicalDigest.tree(
                at: fixture.outputURL
            )
            let beforeContents = try regularFileContents(
                at: fixture.outputURL
            )
            let beforeEntries = try relativeEntries(at: fixture.outputURL)

            #expect(throws: MojoArtifactError.self) {
                _ = try fixture.prepare(
                    forbiddenExecutableImports: true,
                    forbiddenExecutablePathPrefix: fixture.outputURL.path
                )
            }

            #expect(
                try MojoCanonicalDigest.tree(at: fixture.outputURL)
                    == beforeDigest
            )
            #expect(try regularFileContents(at: fixture.outputURL) == beforeContents)
            #expect(try relativeEntries(at: fixture.outputURL) == beforeEntries)
            _ = try fixture.workerVerifier().verify(
                bundleURL: fixture.outputURL
            )
        }
    }
}

private enum WorkerBundleLayoutMutation: String, CaseIterable {
    case extra
    case missing
    case symbolicLink

    var description: String { rawValue }

    func apply(to fixture: WorkerBundleFixture) throws {
        switch self {
        case .extra:
            try Data("ambient".utf8).write(
                to: fixture.outputURL.appendingPathComponent("ambient.bin")
            )
        case .missing:
            try FileManager.default.removeItem(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeWorkerBundle.json"
                )
            )
        case .symbolicLink:
            let libraryURL = fixture.outputURL.appendingPathComponent(
                "lib/libRuntime.dylib"
            )
            try FileManager.default.removeItem(at: libraryURL)
            try FileManager.default.createSymbolicLink(
                at: libraryURL,
                withDestinationURL: fixture.libraryURL
            )
        }
    }
}

private enum WorkerBundleContentMutation: String, CaseIterable {
    case workerManifest
    case runtimeManifest
    case runtimeManifestUnknownKey
    case receipt
    case receiptUnknownKey
    case executable
    case library

    var description: String { rawValue }

    func apply(to fixture: WorkerBundleFixture) throws {
        switch self {
        case .workerManifest:
            try mutateTextFile(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeWorkerBundle.json"
                ),
                fragment: "\"compilerVersion\" : \"fixture-compiler\"",
                replacement:
                    "\"compilerVersion\" : \"fixture-compiler-mutated\""
            )
        case .runtimeManifest:
            try mutateTextFile(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeBundle.json"
                ),
                fragment:
                    "\"loaderSearchPath\" : \"@executable_path\\/..\\/lib\"",
                replacement:
                    "\"loaderSearchPath\" : \"@executable_path\\/..\\/ambient\""
            )
        case .runtimeManifestUnknownKey:
            try mutateTextFile(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeBundle.json"
                ),
                fragment: "\"schemaVersion\" : 1,",
                replacement: "\"schemaVersion\" : 1,\n  \"unknownRuntimeField\" : true,"
            )
        case .receipt:
            try mutateTextFile(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeReceipt.json"
                ),
                fragment: "\"objectDigest\" : \"\(fixture.mojoObjectDigest)\"",
                replacement:
                    "\"objectDigest\" : \"\(flippedDigest(fixture.mojoObjectDigest))\""
            )
        case .receiptUnknownKey:
            try mutateTextFile(
                at: fixture.outputURL.appendingPathComponent(
                    "RuntimeReceipt.json"
                ),
                fragment: "\"schemaVersion\" : 1,",
                replacement: "\"schemaVersion\" : 1,\n  \"unknownReceiptField\" : true,"
            )
        case .executable:
            let url = fixture.outputURL.appendingPathComponent(
                "bin/mojo-worker"
            )
            var data = try Data(contentsOf: url)
            data.append(0xff)
            try data.write(to: url)
        case .library:
            let url = fixture.outputURL.appendingPathComponent(
                "lib/libRuntime.dylib"
            )
            var data = try Data(contentsOf: url)
            data.append(0xff)
            try data.write(to: url)
        }
    }
}

private enum WorkerBundleIdentityMutation: String, CaseIterable {
    case executionContract
    case binding
    case protocolRecord
    case targetClosure

    var description: String { rawValue }

    func apply(
        to fixture: WorkerBundleFixture,
        manifest: MojoRuntimeWorkerBundleManifest
    ) throws {
        let manifestURL = fixture.outputURL.appendingPathComponent(
            "RuntimeWorkerBundle.json"
        )
        switch self {
        case .executionContract:
            try mutateTextFile(
                at: manifestURL,
                fragment:
                    "\"executionContractDigest\" : \"\(manifest.executionContractDigest)\"",
                replacement:
                    "\"executionContractDigest\" : \"\(flippedDigest(manifest.executionContractDigest))\""
            )
        case .binding:
            try mutateTextFile(
                at: manifestURL,
                fragment: "\"functionName\" : \"openSession\"",
                replacement: "\"functionName\" : \"changedSession\""
            )
        case .protocolRecord:
            try mutateTextFile(
                at: manifestURL,
                fragment: "\"maximumFramePayloadBytes\" : 4096",
                replacement: "\"maximumFramePayloadBytes\" : 8192"
            )
        case .targetClosure:
            try mutateTextFile(
                at: manifestURL,
                fragment: "\"targetCPU\" : \"apple-m2-max\"",
                replacement: "\"targetCPU\" : \"apple-m3-max\""
            )
        }
    }
}

private struct WorkerBundleFixture {
    let root: URL
    let inputGraph: MojoInputGraph
    let identity: MojoArtifactIdentity
    let target: MojoTargetConfiguration
    let outputURL: URL
    let mojoSourceURL: URL
    let mojoObjectURL: URL
    let workerSourceURL: URL
    let workerObjectURL: URL
    let libraryURL: URL
    let renderedSources: MojoRuntimeWorkerRenderedSources
    let receipt: MojoRuntimeDependencyReceipt
    let binaryInspector: WorkerBundleBinaryInspector

    var mojoObjectDigest: String {
        renderedSources.executionContract.generatedMojoObjectDigest
    }

    var workerObjectDigest: String {
        get throws {
            try MojoCanonicalDigest.file(at: workerObjectURL)
        }
    }

    init(
        externalFunction: String = "scale",
        includesCallableExport: Bool = false,
        usesPrimaryLibraryName: Bool = false
    ) throws {
        let fileManager = FileManager.default
        root = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-worker-bundle-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        let sourceURL = root.appendingPathComponent("Bindings.swift")
        try """
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
            function: "\(externalFunction)",
            sessionFactory: "openSession"
        )
        func scale(
            _ session: MojoSessionOwner,
            _ input: borrowing Span<Float>,
            into output: inout MutableSpan<Float>
        ) throws
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        inputGraph = MojoInputGraph(
            bindingGraph: try MojoSourceGraph(sourceURLs: [sourceURL])
        )
        identity = try MojoArtifactIdentity(targetName: "WorkerBundleFixture")
        target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m2-max",
            accelerator: "metal"
        )
        outputURL = root.appendingPathComponent(
            "Worker.bundle",
            isDirectory: true
        )
        mojoSourceURL = root.appendingPathComponent("Bindings.mojo")
        mojoObjectURL = root.appendingPathComponent("Bindings.o")
        workerSourceURL = root.appendingPathComponent("RuntimeWorker.c")
        workerObjectURL = root.appendingPathComponent("RuntimeWorker.o")
        let runtimeLibraryName = usesPrimaryLibraryName
            ? "lib\(identity.moduleName).dylib"
            : "libRuntime.dylib"
        libraryURL = root.appendingPathComponent(runtimeLibraryName)

        let mojo = MojoStaticSourceRenderer().render(
            inputGraph: inputGraph,
            identity: identity
        )
        try mojo.source.write(
            to: mojoSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try Data("mojo-object-v1".utf8).write(to: mojoObjectURL)
        try Data("worker-object-v1".utf8).write(to: workerObjectURL)
        try Data("runtime-library-v1".utf8).write(to: libraryURL)

        var runtimeExports: Set<String> = ["AsyncRT_DeviceContext_create"]
        if includesCallableExport {
            runtimeExports.insert(
                "\(identity.symbolPrefix)_input_graph_identifier"
            )
        }
        let libraries = [
            runtimeLibraryName: MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/\(runtimeLibraryName)",
                dynamicDependencies: ["/usr/lib/libSystem.B.dylib"],
                exportedSymbols: runtimeExports
            ),
        ]
        let executable = MojoRuntimeExecutableInspection(
            architecture: "arm64",
            dynamicDependencies: [
                "/usr/lib/libSystem.B.dylib",
                "@rpath/\(runtimeLibraryName)",
            ],
            runtimeSearchPaths: ["@executable_path/../lib"],
            programInterpreter: nil
        )
        binaryInspector = WorkerBundleBinaryInspector(
            libraries: libraries,
            executable: executable
        )
        let receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: binaryInspector,
            processRunner: WorkerBundleProcessRunner()
        )
        receipt = try receiptPreparer.prepare(
            options: MojoRuntimeReceiptOptions(
                objectURL: mojoObjectURL,
                libraryURLs: [libraryURL],
                target: target
            )
        )
        renderedSources = try MojoRuntimeWorkerRenderer().render(
            inputGraph: inputGraph,
            identity: identity,
            target: target,
            compilerIdentity: "fixture-compiler",
            generatedMojoSourceDigest: try MojoCanonicalDigest.file(
                at: mojoSourceURL
            ),
            generatedMojoObjectDigest: try MojoCanonicalDigest.file(
                at: mojoObjectURL
            ),
            receipt: receipt,
            maximumFramePayloadBytes: 4_096
        )
        try renderedSources.header.write(
            to: root.appendingPathComponent("\(identity.moduleName).h"),
            atomically: true,
            encoding: .utf8
        )
        try renderedSources.workerSource.write(
            to: workerSourceURL,
            atomically: true,
            encoding: .utf8
        )
    }

    func options() throws -> MojoRuntimeWorkerBundleOptions {
        try MojoRuntimeWorkerBundleOptions(
            outputDirectoryURL: outputURL,
            executableName: "mojo-worker",
            identity: identity,
            inputGraph: inputGraph,
            renderedSources: renderedSources,
            mojoSourceURL: mojoSourceURL,
            mojoObjectURL: mojoObjectURL,
            workerSourceURL: workerSourceURL,
            workerObjectURL: workerObjectURL,
            runtimeLibraryURLs: [libraryURL],
            target: target
        )
    }

    func prepare(
        forbiddenExecutableImports: Bool = false,
        forbiddenExecutablePathPrefix: String? = nil
    ) throws -> MojoRuntimeWorkerBundleManifest {
        try builder(
            forbiddenExecutableImports: forbiddenExecutableImports,
            forbiddenExecutablePathPrefix: forbiddenExecutablePathPrefix
        ).prepare(receipt: receipt, options: options())
    }

    func builder(
        forbiddenExecutableImports: Bool = false,
        forbiddenExecutablePathPrefix: String? = nil
    ) -> MojoRuntimeWorkerBundleBuilder {
        let receiptVerifier = MojoRuntimeReceiptVerifier(
            preparer: MojoRuntimeReceiptPreparer(
                binaryInspector: binaryInspector,
                processRunner: WorkerBundleProcessRunner()
            )
        )
        return MojoRuntimeWorkerBundleBuilder(
            runtimeBundleBuilder: MojoRuntimeBundleBuilder(
                linker: WorkerBundleExecutableLinker(),
                receiptVerifier: receiptVerifier,
                bundleVerifier: runtimeVerifier()
            ),
            receiptVerifier: receiptVerifier,
            binaryInspector: binaryInspector,
            workerVerifier: workerVerifier(
                forbiddenExecutableImports: forbiddenExecutableImports,
                forbiddenExecutablePathPrefix: forbiddenExecutablePathPrefix
            )
        )
    }

    func runtimeVerifier(
        forbiddenExecutableImports: Bool = false,
        forbiddenExecutablePathPrefix: String? = nil,
        binaryInspector: WorkerBundleBinaryInspector? = nil
    ) -> MojoRuntimeBundleVerifier {
        MojoRuntimeBundleVerifier(
            binaryInspector: binaryInspector ?? self.binaryInspector,
            processRunner: WorkerBundleProcessRunner(
                forbiddenExecutableImports: forbiddenExecutableImports,
                forbiddenExecutablePathPrefix: forbiddenExecutablePathPrefix
            )
        )
    }

    func workerVerifier(
        forbiddenExecutableImports: Bool = false,
        forbiddenExecutablePathPrefix: String? = nil,
        binaryInspector: WorkerBundleBinaryInspector? = nil
    ) -> MojoRuntimeWorkerBundleVerifier {
        let selectedBinaryInspector = binaryInspector ?? self.binaryInspector
        let runner = WorkerBundleProcessRunner(
            forbiddenExecutableImports: forbiddenExecutableImports,
            forbiddenExecutablePathPrefix: forbiddenExecutablePathPrefix
        )
        return MojoRuntimeWorkerBundleVerifier(
            runtimeBundleVerifier: runtimeVerifier(
                forbiddenExecutableImports: forbiddenExecutableImports,
                forbiddenExecutablePathPrefix: forbiddenExecutablePathPrefix,
                binaryInspector: selectedBinaryInspector
            ),
            binaryInspector: selectedBinaryInspector,
            processRunner: runner
        )
    }
}

private func withWorkerBundleFixture(
    externalFunction: String = "scale",
    includesCallableExport: Bool = false,
    usesPrimaryLibraryName: Bool = false,
    _ body: (WorkerBundleFixture) throws -> Void
) throws {
    let fixture = try WorkerBundleFixture(
        externalFunction: externalFunction,
        includesCallableExport: includesCallableExport,
        usesPrimaryLibraryName: usesPrimaryLibraryName
    )
    defer {
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            Issue.record("Failed to remove runtime worker bundle fixture: \(error)")
        }
    }
    try body(fixture)
}

private func expectWorkerBundleRejection(
    _ mutation: String,
    verifier: MojoRuntimeWorkerBundleVerifier,
    bundleURL: URL
) throws {
    do {
        _ = try verifier.verify(bundleURL: bundleURL)
        Issue.record("Worker bundle mutation '\(mutation)' unexpectedly verified")
    } catch {
        return
    }
}

private func mutateTextFile(
    at url: URL,
    fragment: String,
    replacement: String
) throws {
    let source = try String(contentsOf: url, encoding: .utf8)
    let occurrences = source.components(separatedBy: fragment).count - 1
    guard occurrences == 1 else {
        throw MojoArtifactError.invalidArguments(
            "Expected exactly one '\(fragment)' mutation site, found \(occurrences)"
        )
    }
    try source.replacingOccurrences(
        of: fragment,
        with: replacement
    ).write(to: url, atomically: true, encoding: .utf8)
}

private func flippedDigest(_ digest: String) -> String {
    let replacement = digest.first == "0" ? "1" : "0"
    return replacement + digest.dropFirst()
}

private func relativeEntries(at root: URL) throws -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: nil
    ) else {
        throw MojoArtifactError.invalidArguments(
            "Could not enumerate worker bundle fixture"
        )
    }
    let prefix = root.resolvingSymlinksInPath().path + "/"
    var entries = Set<String>()
    for case let url as URL in enumerator {
        let resolvedPath = url.resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(prefix) else {
            throw MojoArtifactError.invalidArguments(
                "Worker bundle enumeration escaped its fixture root"
            )
        }
        entries.insert(String(resolvedPath.dropFirst(prefix.count)))
    }
    return entries
}

private func regularFileContents(at root: URL) throws -> [String: Data] {
    var contents: [String: Data] = [:]
    for relativePath in try relativeEntries(at: root) {
        let url = root.appendingPathComponent(relativePath)
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        if values.isRegularFile == true,
           values.isSymbolicLink != true {
            contents[relativePath] = try Data(
                contentsOf: url,
                options: .mappedIfSafe
            )
        }
    }
    return contents
}
