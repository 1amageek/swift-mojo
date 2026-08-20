import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

private struct FixtureMojoCompiler: MojoObjectCompiling {
    func compilerVersion() throws -> String {
        "fixture-mojo 1.0"
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        let generatedSource = try String(
            contentsOf: URL(fileURLWithPath: inputPath),
            encoding: .utf8
        )
        if generatedSource.contains("__swift_mojo_external_") {
            guard !importSearchPaths.isEmpty,
                  importSearchPaths.allSatisfy({
                    NSString(string: $0).isAbsolutePath
                        && URL(fileURLWithPath: $0).lastPathComponent
                            == ".imports"
                  }) else {
                throw MojoArtifactError.invalidArguments(
                    "External package compile requires absolute import roots"
                )
            }
            let visiblePackages = try FileManager.default
                .contentsOfDirectory(
                    atPath: importSearchPaths[0]
                )
            guard visiblePackages == ["MathModel"] else {
                throw MojoArtifactError.invalidArguments(
                    "Compiler import root exposed undeclared packages"
                )
            }
        }
        try Data("fixture object \(target.identity)".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        return ""
    }
}

private struct FixtureDiagnosticCompiler: MojoObjectCompiling {
    func compilerVersion() throws -> String {
        "fixture-mojo 1.0"
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        let source = try String(
            contentsOf: URL(fileURLWithPath: inputPath),
            encoding: .utf8
        )
        guard let index = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).firstIndex(where: { $0.contains("return lhs + rhs") }) else {
            throw MojoArtifactError.invalidArguments(
                "Fixture generated dispatch line is missing"
            )
        }
        throw MojoCompilerToolError.commandFailed(
            command: "fixture mojo build",
            status: 1,
            diagnostic: "\(inputPath):\(index + 1):9: error: fixture diagnostic"
        )
    }
}

private struct FixtureSourceMutatingCompiler: MojoObjectCompiling {
    let sourceURL: URL

    func compilerVersion() throws -> String {
        "fixture-mojo 1.0"
    }

    func compileObject(
        inputPath: String,
        outputPath: String,
        target: MojoTargetConfiguration,
        importSearchPaths: [String]
    ) throws -> String {
        try Data("fixture object \(target.identity)".utf8).write(
            to: URL(fileURLWithPath: outputPath)
        )
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return b + a
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        return ""
    }
}

private struct FixturePackagingRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        switch executablePath {
        case "/usr/bin/ar":
            guard arguments.count == 3 else {
                throw MojoArtifactError.invalidArguments("Unexpected ar arguments")
            }
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: arguments[2]),
                to: URL(fileURLWithPath: arguments[1])
            )
        case "/usr/bin/xcrun":
            switch arguments.first {
            case "lipo":
                try createUniversalArchive(arguments: arguments)
            case "xcodebuild":
                try createXCFramework(arguments: arguments)
            default:
                throw MojoArtifactError.invalidArguments(
                    "Unexpected xcrun arguments: \(arguments)"
                )
            }
        default:
            throw MojoArtifactError.invalidArguments(
                "Unexpected fixture command: \(executablePath)"
            )
        }
        return MojoProcessResult(status: 0, output: "")
    }

    private func createXCFramework(arguments: [String]) throws {
        let archives = try requiredValues(after: "-library", in: arguments)
        let headers = try requiredValue(after: "-headers", in: arguments)
        let output = try requiredValue(after: "-output", in: arguments)
        let artifactURL = URL(fileURLWithPath: output, isDirectory: true)
        for (index, archive) in archives.enumerated() {
            let sliceURL = artifactURL.appendingPathComponent(
                "fixture-slice-\(index)",
                isDirectory: true
            )
            let destinationHeaders = sliceURL.appendingPathComponent(
                "Headers",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: destinationHeaders,
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: archive),
                to: sliceURL.appendingPathComponent(
                    URL(fileURLWithPath: archive).lastPathComponent
                )
            )
            let headerURLs = try FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: headers),
                includingPropertiesForKeys: nil
            )
            for headerURL in headerURLs {
                try FileManager.default.copyItem(
                    at: headerURL,
                    to: destinationHeaders.appendingPathComponent(
                        headerURL.lastPathComponent
                    )
                )
            }
        }
        let libraries: [[String: Any]] = try archives.enumerated().map {
            index,
            archive in
            [
                "LibraryIdentifier": "fixture-slice-\(index)",
                "LibraryPath": URL(fileURLWithPath: archive).lastPathComponent,
                "HeadersPath": "Headers",
                "SupportedArchitectures": try architectures(in: archive),
                "SupportedPlatform": "macos",
            ]
        }
        let plist = try PropertyListSerialization.data(
            fromPropertyList: [
                "AvailableLibraries": libraries,
                "CFBundlePackageType": "XFWK",
                "XCFrameworkFormatVersion": "1.0",
            ],
            format: .xml,
            options: 0
        )
        try plist.write(to: artifactURL.appendingPathComponent("Info.plist"))
    }

    private func createUniversalArchive(arguments: [String]) throws {
        guard arguments.first == "lipo",
              let createIndex = arguments.firstIndex(of: "-create"),
              let outputIndex = arguments.firstIndex(of: "-output"),
              createIndex < outputIndex else {
            throw MojoArtifactError.invalidArguments(
                "Unexpected lipo arguments"
            )
        }
        let inputStart = arguments.index(after: createIndex)
        let inputs = arguments[inputStart..<outputIndex]
        let outputValueIndex = arguments.index(after: outputIndex)
        guard !inputs.isEmpty,
              outputValueIndex < arguments.endIndex else {
            throw MojoArtifactError.invalidArguments(
                "Incomplete lipo arguments"
            )
        }
        var data = Data()
        for input in inputs {
            data.append(try Data(contentsOf: URL(fileURLWithPath: input)))
        }
        try data.write(
            to: URL(fileURLWithPath: arguments[outputValueIndex])
        )
    }

    private func architectures(in archive: String) throws -> [String] {
        let contents = try String(
            contentsOf: URL(fileURLWithPath: archive),
            encoding: .utf8
        )
        var result: [String] = []
        if contents.contains("arm64-") || contents.contains("aarch64-") {
            result.append("arm64")
        }
        if contents.contains("x86_64-") {
            result.append("x86_64")
        }
        guard !result.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "Fixture archive has no target architecture"
            )
        }
        return result.sorted()
    }

    private func requiredValue(
        after option: String,
        in arguments: [String]
    ) throws -> String {
        guard let optionIndex = arguments.firstIndex(of: option) else {
            throw MojoArtifactError.invalidArguments(
                "Missing fixture option \(option)"
            )
        }
        let valueIndex = arguments.index(after: optionIndex)
        guard valueIndex < arguments.endIndex else {
            throw MojoArtifactError.invalidArguments(
                "Missing fixture value for \(option)"
            )
        }
        return arguments[valueIndex]
    }

    private func requiredValues(
        after option: String,
        in arguments: [String]
    ) throws -> [String] {
        var values: [String] = []
        for index in arguments.indices where arguments[index] == option {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw MojoArtifactError.invalidArguments(
                    "Missing fixture value for \(option)"
                )
            }
            values.append(arguments[valueIndex])
        }
        guard !values.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "Missing fixture option \(option)"
            )
        }
        return values
    }
}

@Suite("Mojo artifact preparation")
struct MojoArtifactPreparerTests {
    @Test(.timeLimit(.minutes(1)))
    func preparesBorrowedFloatBufferABIAndTypedSwiftRegistry() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bindings.swift")
        let package = root.appendingPathComponent(
            "Mojo/MathModel",
            isDirectory: true
        )
        let output = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove buffer ABI fixture: \(error)")
            }
        }
        try """
        from memory import UnsafePointer

        def sum(
            values: UnsafePointer[Float32, ImmutExternalOrigin],
            count: UInt64,
        ) -> Float32:
            var result = Float32(0)
            for index in range(Int(count)):
                result += values[index]
            return result
        """.write(
            to: package.appendingPathComponent("__init__.mojo"),
            atomically: true,
            encoding: .utf8
        )
        try """
        @mojo(package: "MathModel", function: "sum")
        func sum(_ values: [Float]) throws -> Float
        """.write(to: source, atomically: true, encoding: .utf8)
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )
        let identity = try MojoArtifactIdentity(targetName: "Math")
        let externalPackage = try MojoExternalPackage(
            name: "MathModel",
            rootURL: package
        )
        let options = try MojoPrepareOptions(
            sourceURLs: [source],
            sourceRootURL: root,
            externalPackages: [externalPackage],
            outputDirectoryURL: output,
            identity: identity,
            targets: [target]
        )
        let result = try MojoArtifactPreparer(
            compiler: FixtureMojoCompiler(),
            processRunner: FixturePackagingRunner()
        ).prepare(options: options)
        let generatedMojo = try String(
            contentsOf: output.appendingPathComponent("Bindings.mojo"),
            encoding: .utf8
        )
        let header = try String(
            contentsOf: output
                .appendingPathComponent(identity.artifactName)
                .appendingPathComponent("fixture-slice-0/Headers")
                .appendingPathComponent("\(identity.moduleName).h"),
            encoding: .utf8
        )
        let registryURL = root.appendingPathComponent("Registry.swift")
        _ = try MojoArtifactVerifier().verify(
            options: MojoVerifyOptions(
                sourceURLs: [source],
                sourceRootURL: root,
                externalPackages: [externalPackage],
                outputDirectoryURL: output,
                generatedSourceURL: registryURL,
                target: target,
                expectedIdentity: identity
            )
        )
        let registry = try String(
            contentsOf: registryURL,
            encoding: .utf8
        )
        let inputGraph = try options.inputGraph()

        #expect(
            result.manifest.bindings.count == 1
        )
        #expect(generatedMojo.contains("from memory import UnsafePointer"))
        #expect(generatedMojo.contains("_call_f32_buffer_f32"))
        #expect(!generatedMojo.contains("_call_i32_i32_i32"))
        #expect(generatedMojo.contains("UnsafePointer[Float32, ImmutExternalOrigin]"))
        #expect(generatedMojo.contains(") abi(\"C\") -> Float32:"))
        #expect(!generatedMojo.contains("MutExternalOrigin"))
        #expect(!generatedMojo.contains("result[]"))
        #expect(
            header.contains(
                "float \(identity.symbolPrefix)_call_f32_buffer_f32("
            )
        )
        #expect(header.contains("const float *values"))
        #expect(!header.contains("float *result"))
        #expect(!header.contains("_call_i32_i32_i32"))
        #expect(registry.contains("import Mojo"))
        #expect(registry.contains("values: borrowing [Float]"))
        #expect(registry.contains("values.withUnsafeBufferPointer"))
        #expect(registry.contains("private static let artifactValidationError"))
        #expect(registry.contains("MojoInvocationError"))
        #expect(registry.contains("incompatibleStaticABI"))
        #expect(registry.contains("inputGraphMismatch"))
        #expect(registry.contains("!buffer.isEmpty"))
        #expect(registry.contains("_call_f32_buffer_f32"))
        #expect(!registry.contains("var result"))
        #expect(!registry.contains("let status"))
        #expect(!registry.contains("preparedBindingIDs.contains"))
        #expect(
            registry.components(
                separatedBy: "_static_abi_version()"
            ).count == 2
        )
        #expect(
            registry.components(
                separatedBy: "_has_binding(bindingID)"
            ).count == 2
        )
        #expect(
            result.manifest.generationPipelineDigest
                == MojoGenerationPipeline.digest(for: inputGraph)
        )
        #expect(
            result.manifest.generationPipelineDigest
                != MojoGenerationPipeline.digest
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func preparesExternalPackageAndInvalidatesItByContent() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let source = root.appendingPathComponent("Bindings.swift")
        let package = root.appendingPathComponent(
            "Mojo/MathModel",
            isDirectory: true
        )
        let output = root.appendingPathComponent("Generated", isDirectory: true)
        try fileManager.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove external package fixture: \(error)")
            }
        }
        try "from .math import add\n".write(
            to: package.appendingPathComponent("__init__.mojo"),
            atomically: true,
            encoding: .utf8
        )
        let implementation = package.appendingPathComponent("math.mojo")
        try "fn add(a: Int32, b: Int32) -> Int32:\n    return a + b\n".write(
            to: implementation,
            atomically: true,
            encoding: .utf8
        )
        try """
        @mojo(package: "MathModel", function: "add")
        func add(_ a: Int32, _ b: Int32) -> Int32
        """.write(to: source, atomically: true, encoding: .utf8)
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )
        let identity = try MojoArtifactIdentity(targetName: "Math")
        let preparer = MojoArtifactPreparer(
            compiler: FixtureMojoCompiler(),
            processRunner: FixturePackagingRunner()
        )
        let firstOptions = try MojoPrepareOptions(
            sourceURLs: [source],
            sourceRootURL: root,
            externalPackages: [
                MojoExternalPackage(name: "MathModel", rootURL: package),
            ],
            outputDirectoryURL: output,
            identity: identity,
            targets: [target]
        )
        let first = try preparer.prepare(options: firstOptions)
        let generated = try String(
            contentsOf: output.appendingPathComponent("Bindings.mojo"),
            encoding: .utf8
        )
        #expect(generated.contains("from MathModel import add"))

        try "fn add(a: Int32, b: Int32) -> Int32:\n    return b + a\n".write(
            to: implementation,
            atomically: true,
            encoding: .utf8
        )
        let changedOptions = try MojoPrepareOptions(
            sourceURLs: [source],
            sourceRootURL: root,
            externalPackages: [
                MojoExternalPackage(name: "MathModel", rootURL: package),
            ],
            outputDirectoryURL: output,
            identity: identity,
            targets: [target]
        )
        let changed = try preparer.prepare(options: changedOptions)

        #expect(first.manifest.inputGraphDigest != changed.manifest.inputGraphDigest)
        #expect(changed.disposition == .prepared)
    }

    @Test(.timeLimit(.minutes(1)))
    func externalPackageRejectsCompilerVisibleSymbolicLinks() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        let package = root.appendingPathComponent(
            "Mojo/MathModel",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove symbolic-link fixture: \(error)")
            }
        }
        try "fn add(a: Int32, b: Int32) -> Int32:\n    return a + b\n"
            .write(
                to: package.appendingPathComponent("__init__.mojo"),
                atomically: true,
                encoding: .utf8
            )
        let outside = root.appendingPathComponent("outside.mojo")
        try "fn hidden():\n    pass\n".write(
            to: outside,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.createSymbolicLink(
            at: package.appendingPathComponent("hidden.mojo"),
            withDestinationURL: outside
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try MojoExternalPackage(
                name: "MathModel",
                rootURL: package
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func preparesAllDeclaredSlicesInOneArtifactSet() throws {
        try withPreparerFixture { fixture in
            let targets = try [
                MojoTargetConfiguration(
                    triple: "arm64-apple-macosx14.0",
                    cpu: "generic"
                ),
                MojoTargetConfiguration(
                    triple: "x86_64-apple-macosx14.0",
                    cpu: "x86-64"
                ),
            ]
            let options = try MojoPrepareOptions(
                sourceURLs: [fixture.sourceURL],
                outputDirectoryURL: fixture.outputDirectory,
                identity: MojoArtifactIdentity(targetName: "MultiSlice"),
                targets: targets
            )
            let result = try MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner()
            ).prepare(options: options)

            #expect(result.manifest.effectiveSlices.map(\.target) == targets)
            #expect(result.manifest.effectiveSlices.count == 2)
            #expect(
                Set(result.manifest.effectiveSlices.map(\.libraryIdentifier))
                    .count == 1
            )
            #expect(
                Set(result.manifest.effectiveSlices.map(\.archiveDigest))
                    .count == 1
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func duplicateXCFrameworkSelectorsAreRejectedBeforeCompilation() throws {
        try withPreparerFixture { fixture in
            let first = try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "apple-m1"
            )
            let second = try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "apple-m2"
            )

            #expect(throws: MojoArtifactError.self) {
                _ = try MojoPrepareOptions(
                    sourceURLs: [fixture.sourceURL],
                    outputDirectoryURL: fixture.outputDirectory,
                    identity: MojoArtifactIdentity(targetName: "Duplicate"),
                    targets: [first, second]
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func releaseConfigurationRejectsDuplicateXCFrameworkSelectors() throws {
        let first = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m1"
        )
        let second = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m2"
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try SwiftMojoConfiguration.Target(
                compilerVersion: "fixture-mojo 1.0",
                mojoPackages: [],
                slices: [first, second]
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func releaseConfigurationRejectsUnknownSchemaKeys() {
        let data = Data(
            """
            {
              "schemaVersion": 1,
              "targets": {
                "Model": {
                  "compilerVersion": "fixture-mojo 1.0",
                  "mojoPackages": [],
                  "slices": [
                    {
                      "triple": "arm64-apple-macosx14.0",
                      "cpu": "generic",
                      "untrackedFeature": "value"
                    }
                  ]
                }
              }
            }
            """.utf8
        )

        #expect(throws: MojoArtifactError.self) {
            _ = try SwiftMojoConfiguration.decode(data)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func absoluteGeneratedDiagnosticPathMapsToSwiftSource() throws {
        let reference = MojoSourceReference(
            file: "Sources/Model/Bindings.swift",
            line: 8,
            column: 5
        )
        let sourceMap = MojoSourceMap(
            inputGraphDigest: "fixture",
            entries: [
                MojoSourceMap.Entry(
                    generatedLine: 24,
                    bindingID: 1,
                    source: reference
                ),
            ]
        )
        let generatedPath = "/private/tmp/swift-mojo/Bindings.mojo"
        let diagnostic = "\(generatedPath):24:11: error: fixture"

        #expect(
            sourceMap.remap(
                diagnostic: diagnostic,
                generatedSourcePath: generatedPath
            ) == "Sources/Model/Bindings.swift:8:5: error: fixture"
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func preparationReturnsCompilerDiagnosticAtSwiftDeclaration() throws {
        try withPreparerFixture { fixture in
            do {
                _ = try MojoArtifactPreparer(
                    compiler: FixtureDiagnosticCompiler(),
                    processRunner: FixturePackagingRunner()
                ).prepare(options: fixture.options)
                Issue.record("Fixture compiler failure unexpectedly succeeded")
            } catch let error as MojoArtifactError {
                guard case .compilerDiagnostic(_, let status, let diagnostic)
                    = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(status == 1)
                #expect(
                    diagnostic.contains(
                        "Bindings.swift:1:1: error: fixture diagnostic"
                    )
                )
                #expect(!diagnostic.contains(".swift-mojo-staging"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func sourceChangeDuringCompilationPreventsArtifactCommit() throws {
        try withPreparerFixture { fixture in
            #expect(
                throws: MojoArtifactError.inputsChangedDuringOperation(
                    "artifact preparation"
                )
            ) {
                _ = try MojoArtifactPreparer(
                    compiler: FixtureSourceMutatingCompiler(
                        sourceURL: fixture.sourceURL
                    ),
                    processRunner: FixturePackagingRunner()
                ).prepare(options: fixture.options)
            }
            #expect(
                !FileManager.default.fileExists(
                    atPath: fixture.outputDirectory.path
                )
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func generationPipelineChangeInvalidatesCache() throws {
        try withPreparerFixture { fixture in
            let firstPreparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-a"
            )
            let first = try firstPreparer.prepare(options: fixture.options)
            let reused = try firstPreparer.prepare(options: fixture.options)
            let changedPreparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-b"
            )
            let regenerated = try changedPreparer.prepare(options: fixture.options)

            #expect(first.disposition == .prepared)
            #expect(reused.disposition == .reused)
            #expect(regenerated.disposition == .prepared)
            #expect(regenerated.manifest.generationPipelineDigest == "pipeline-b")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func scalarPipelinePreservesTheReleasedGenerationIdentity() throws {
        try withPreparerFixture { fixture in
            let inputGraph = try fixture.options.inputGraph()

            #expect(
                MojoGenerationPipeline.digest(for: inputGraph)
                    == MojoGenerationPipeline.digest
            )
            #expect(
                MojoGenerationPipeline.digest
                    == "9663f12deb5cb466972f7179445f229676dfc7cea813a10ec303600481735dab"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verifierRejectsDifferentGenerationPipeline() throws {
        try withPreparerFixture { fixture in
            let preparer = MojoArtifactPreparer(
                compiler: FixtureMojoCompiler(),
                processRunner: FixturePackagingRunner(),
                generationPipelineDigest: "pipeline-a"
            )
            _ = try preparer.prepare(options: fixture.options)
            let verifier = MojoArtifactVerifier(
                generationPipelineDigest: "pipeline-b"
            )
            let generated = fixture.root.appendingPathComponent("Registry.swift")

            #expect(
                throws: MojoArtifactError.generationPipelineMismatch(
                    expected: "pipeline-b",
                    actual: "pipeline-a"
                )
            ) {
                _ = try verifier.verify(
                    options: MojoVerifyOptions(
                        sourceURLs: [fixture.sourceURL],
                        outputDirectoryURL: fixture.outputDirectory,
                        generatedSourceURL: generated,
                        targetTriple: "arm64-apple-macosx14.0",
                        targetCPU: "generic"
                    )
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func outputLockSerializesConcurrentCriticalSections() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: root)
            } catch {
                Issue.record("Failed to remove lock fixture: \(error)")
            }
        }
        let output = root.appendingPathComponent("Generated", isDirectory: true)
        let stateURL = root.appendingPathComponent("state.txt")
        let transaction = MojoOutputTransaction()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for value in 0..<8 {
                group.addTask {
                    let taskFileManager = FileManager.default
                    try transaction.withExclusiveAccess(to: output) { _ in
                        var state: Data
                        if taskFileManager.fileExists(atPath: stateURL.path) {
                            state = try Data(contentsOf: stateURL)
                        } else {
                            state = Data()
                        }
                        state.append(Data("\(value)\n".utf8))
                        try state.write(to: stateURL, options: .atomic)
                    }
                }
            }
            try await group.waitForAll()
        }

        let lines = try String(contentsOf: stateURL, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 8)
        #expect(Set(lines).count == 8)
    }
}

private struct PreparerFixture {
    let root: URL
    let sourceURL: URL
    let outputDirectory: URL
    let options: MojoPrepareOptions

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        sourceURL = root.appendingPathComponent("Bindings.swift")
        outputDirectory = root.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try """
        @mojo
        func add(_ a: Int32, _ b: Int32) -> Int32 {
            return a + b
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)
        options = try MojoPrepareOptions(
            sourceURLs: [sourceURL],
            outputDirectoryURL: outputDirectory,
            targetTriple: "arm64-apple-macosx14.0",
            targetCPU: "generic"
        )
    }
}

private func withPreparerFixture(
    _ body: (PreparerFixture) throws -> Void
) throws {
    let fixture = try PreparerFixture()
    defer {
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            Issue.record("Failed to remove preparer fixture: \(error)")
        }
    }
    try body(fixture)
}
