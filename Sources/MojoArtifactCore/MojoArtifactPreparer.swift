import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoArtifactPreparer: Sendable {
    package static let packagingVersion = 8

    private let compiler: any MojoObjectCompiling
    private let generationPipelineDigestOverride: String?
    private let linkageInspector: MojoObjectLinkageInspector
    private let processRunner: any MojoProcessRunning
    private let renderer: MojoStaticSourceRenderer
    private let staticArchiveBuilder: MojoStaticArchiveBuilder
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try self.init(
            compiler: MojoCompiler(environment: environment),
            processRunner: FoundationMojoProcessRunner(environment: environment),
            environment: environment
        )
    }

    package init(
        compiler: any MojoObjectCompiling,
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        generationPipelineDigest: String? = nil,
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.compiler = compiler
        self.generationPipelineDigestOverride = generationPipelineDigest
        self.linkageInspector = MojoObjectLinkageInspector(
            processRunner: processRunner
        )
        self.processRunner = processRunner
        self.renderer = renderer
        self.staticArchiveBuilder = MojoStaticArchiveBuilder(
            processRunner: processRunner,
            environment: environment
        )
        self.transaction = transaction
    }

    @discardableResult
    package func prepare(options: MojoPrepareOptions) throws -> MojoPrepareResult {
        try transaction.withExclusiveAccess(to: options.outputDirectoryURL) { access in
            try prepare(options: options, access: access)
        }
    }

    private func prepare(
        options: MojoPrepareOptions,
        access: MojoOutputTransaction.ExclusiveAccess
    ) throws -> MojoPrepareResult {
        try options.targets.forEach { target in
            try Self.validate(target: target)
        }
        let inputGraph = try options.inputGraph()
        let generationPipelineDigest = generationPipelineDigestOverride
            ?? MojoGenerationPipeline.digest(for: inputGraph)
        let compilerVersion = try compiler.compilerVersion()
        if let expected = options.expectedCompilerVersion,
           compilerVersion != expected {
            throw MojoArtifactError.compilerVersionMismatch(
                expected: expected,
                actual: compilerVersion
            )
        }
        if let manifest = try cachedManifest(
            options: options,
            inputGraph: inputGraph,
            compilerVersion: compilerVersion,
            generationPipelineDigest: generationPipelineDigest
        ) {
            return MojoPrepareResult(manifest: manifest, disposition: .reused)
        }

        let staging = try transaction.makeStagingDirectory(
            for: options.outputDirectoryURL
        )
        do {
            let rendered = renderer.render(
                inputGraph: inputGraph,
                identity: options.identity
            )
            let sourceURL = staging.appendingPathComponent(
                MojoStaticABI.generatedMojoSourceName
            )
            let sourceMapURL = staging.appendingPathComponent(
                MojoStaticABI.sourceMapName
            )
            let sourceMapData = try rendered.sourceMap.encode()
            let generatedSourceData = Data(rendered.source.utf8)
            try rendered.source.write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            try sourceMapData.write(to: sourceMapURL, options: .atomic)

            let renderedHeader = renderer.header(
                identity: options.identity,
                inputGraph: inputGraph
            )
            let buildURL = staging.appendingPathComponent(
                ".slices",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: buildURL,
                withIntermediateDirectories: true
            )
            let importRootURL = try MojoExternalPackageImportRoot.create(
                in: staging,
                externalPackages: inputGraph.externalPackages
            )
            let importSearchPaths = importRootURL.map { [$0.path] } ?? []
            var builtArchives: [(MojoTargetConfiguration, URL)] = []
            for (index, target) in options.targets.enumerated() {
                let directory = buildURL.appendingPathComponent(
                    "slice-\(index)",
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let objectURL = directory.appendingPathComponent("Bindings.o")
                let archiveURL = directory.appendingPathComponent(
                    options.identity.libraryName
                )
                do {
                    _ = try compiler.compileObject(
                        inputPath: sourceURL.path,
                        outputPath: objectURL.path,
                        target: target,
                        importSearchPaths: importSearchPaths
                    )
                } catch let error as MojoCompilerToolError {
                    if case .commandFailed(
                        let command,
                        let status,
                        let diagnostic
                    ) = error {
                        throw MojoArtifactError.compilerDiagnostic(
                            command: command,
                            status: status,
                            diagnostic: rendered.sourceMap.remap(
                                diagnostic: diagnostic,
                                generatedSourcePath: sourceURL.path
                            )
                        )
                    }
                    throw error
                }
                try linkageInspector.validate(
                    objectURL: objectURL,
                    target: target
                )
                try staticArchiveBuilder.build(
                    objectURL: objectURL,
                    archiveURL: archiveURL,
                    target: target
                )
                builtArchives.append(
                    (
                        target,
                        archiveURL
                    )
                )
            }

            let packaged = try packageArtifacts(
                builtArchives,
                header: renderedHeader,
                in: staging,
                identity: options.identity
            )
            let manifest = MojoArtifactManifest(
                compilerVersion: compilerVersion,
                artifactIdentity: options.identity,
                inputGraph: inputGraph,
                slices: packaged.slices,
                generatedSourceDigest: MojoCanonicalDigest.hex(
                    generatedSourceData
                ),
                sourceMapDigest: MojoCanonicalDigest.hex(sourceMapData),
                artifacts: packaged.artifacts,
                generationPipelineDigest: generationPipelineDigest
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(MojoStaticABI.manifestName),
                options: .atomic
            )
            try FileManager.default.removeItem(at: buildURL)
            let libraryBuildURL = staging.appendingPathComponent(
                ".libraries",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: libraryBuildURL.path) {
                try FileManager.default.removeItem(at: libraryBuildURL)
            }
            let frameworkBuildURL = staging.appendingPathComponent(
                ".frameworks",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: frameworkBuildURL.path) {
                try FileManager.default.removeItem(at: frameworkBuildURL)
            }
            if let importRootURL {
                try FileManager.default.removeItem(at: importRootURL)
            }
            guard try options.inputGraph() == inputGraph else {
                throw MojoArtifactError.inputsChangedDuringOperation(
                    "artifact preparation"
                )
            }
            try transaction.commit(
                stagingURL: staging,
                outputURL: options.outputDirectoryURL,
                access: access
            )
            return MojoPrepareResult(manifest: manifest, disposition: .prepared)
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: staging.path) {
                    try FileManager.default.removeItem(at: staging)
                }
            } catch let cleanupError {
                throw MojoArtifactError.commandFailed(
                    command: "clean prepare staging directory",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
    }

    private func run(executablePath: String, arguments: [String]) throws {
        let result = try processRunner.capture(
            executablePath: executablePath,
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: result.status,
                diagnostic: result.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func packageArtifacts(
        _ builtArchives: [(MojoTargetConfiguration, URL)],
        header: String,
        in stagingURL: URL,
        identity: MojoArtifactIdentity
    ) throws -> (
        artifacts: [MojoArtifactManifest.Artifact],
        slices: [MojoArtifactManifest.Slice]
    ) {
        let groups = try Dictionary(grouping: builtArchives) { archive in
            try MojoNativeArtifactAdapter(target: archive.0)
        }
        var artifacts: [MojoArtifactManifest.Artifact] = []
        var slices: [MojoArtifactManifest.Slice] = []

        if let archives = groups[.appleXCFramework] {
            let artifactURL = stagingURL.appendingPathComponent(
                identity.artifactName,
                isDirectory: true
            )
            let packagedArchives = try packageAppleLibraries(
                archives,
                in: stagingURL,
                identity: identity
            )
            let frameworks = try createStaticFrameworks(
                from: packagedArchives,
                header: header,
                in: stagingURL,
                identity: identity
            )
            var arguments = ["xcodebuild", "-create-xcframework"]
            for frameworkURL in frameworks {
                arguments.append(
                    contentsOf: ["-framework", frameworkURL.path]
                )
            }
            arguments.append(contentsOf: ["-output", artifactURL.path])
            try run(
                executablePath: "/usr/bin/xcrun",
                arguments: arguments
            )
            let appleSlices = try MojoXCFrameworkInspector.resolveSlices(
                artifactURL: artifactURL,
                identity: identity,
                targets: archives.map(\.0)
            )
            try MojoXCFrameworkInspector.validate(
                artifactURL: artifactURL,
                identity: identity,
                slices: appleSlices
            )
            slices.append(contentsOf: appleSlices)
            artifacts.append(
                MojoArtifactManifest.Artifact(
                    adapter: .appleXCFramework,
                    name: identity.artifactName,
                    digest: try MojoCanonicalDigest.tree(at: artifactURL)
                )
            )
        }

        if let archives = groups[.linuxStaticLibraryBundle] {
            let artifactURL = stagingURL.appendingPathComponent(
                identity.linuxArtifactName,
                isDirectory: true
            )
            let linuxSlices = try MojoStaticLibraryArtifactBundleLayout.create(
                at: artifactURL,
                identity: identity,
                archives: archives.map {
                    (target: $0.0, archiveURL: $0.1)
                },
                header: header,
                moduleMap: renderer.moduleMap(identity: identity)
            )
            slices.append(contentsOf: linuxSlices)
            artifacts.append(
                MojoArtifactManifest.Artifact(
                    adapter: .linuxStaticLibraryBundle,
                    name: identity.linuxArtifactName,
                    digest: try MojoCanonicalDigest.tree(at: artifactURL)
                )
            )
        }

        return (
            artifacts: artifacts.sorted {
                $0.adapter.rawValue < $1.adapter.rawValue
            },
            slices: slices.sorted { $0.target.identity < $1.target.identity }
        )
    }

    private func packageAppleLibraries(
        _ builtArchives: [(MojoTargetConfiguration, URL)],
        in stagingURL: URL,
        identity: MojoArtifactIdentity
    ) throws -> [URL] {
        var groups: [String: [(MojoTargetConfiguration, URL)]] = [:]
        for builtArchive in builtArchives {
            let selector = try MojoXCFrameworkSliceIdentity(
                target: builtArchive.0
            )
            groups[selector.libraryGroupIdentity, default: []].append(
                builtArchive
            )
        }

        let libraryBuildURL = stagingURL.appendingPathComponent(
            ".libraries",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: libraryBuildURL,
            withIntermediateDirectories: false
        )
        var result: [URL] = []
        for (index, key) in groups.keys.sorted().enumerated() {
            let group = groups[key, default: []].sorted {
                $0.0.identity < $1.0.identity
            }
            guard group.count > 1 else {
                guard let archiveURL = group.first?.1 else {
                    throw MojoArtifactError.sliceResolutionFailed(key)
                }
                result.append(archiveURL)
                continue
            }
            let directory = libraryBuildURL.appendingPathComponent(
                "library-\(index)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            let combinedArchiveURL = directory.appendingPathComponent(
                identity.libraryName
            )
            try run(
                executablePath: "/usr/bin/xcrun",
                arguments: ["lipo", "-create"]
                    + group.map(\.1.path)
                    + ["-output", combinedArchiveURL.path]
            )
            result.append(combinedArchiveURL)
        }
        return result
    }

    private func createStaticFrameworks(
        from archives: [URL],
        header: String,
        in stagingURL: URL,
        identity: MojoArtifactIdentity
    ) throws -> [URL] {
        let frameworkBuildURL = stagingURL.appendingPathComponent(
            ".frameworks",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: frameworkBuildURL,
            withIntermediateDirectories: false
        )
        var result: [URL] = []
        for (index, archiveURL) in archives.enumerated() {
            let sliceBuildURL = frameworkBuildURL.appendingPathComponent(
                "framework-\(index)",
                isDirectory: true
            )
            let frameworkURL = MojoStaticFrameworkLayout.frameworkURL(
                in: sliceBuildURL,
                identity: identity
            )
            try MojoStaticFrameworkLayout.createFramework(
                at: frameworkURL,
                identity: identity,
                archiveURL: archiveURL,
                header: header,
                moduleMap: renderer.frameworkModuleMap(identity: identity)
            )
            result.append(frameworkURL)
        }
        return result
    }

    private static func validate(target: MojoTargetConfiguration) throws {
        _ = try MojoNativeArtifactAdapter(target: target)
    }

    private func cachedManifest(
        options: MojoPrepareOptions,
        inputGraph: MojoInputGraph,
        compilerVersion: String,
        generationPipelineDigest: String
    ) throws -> MojoArtifactManifest? {
        let fileManager = FileManager.default
        let artifactURLs = try options.artifactURLs
        guard fileManager.fileExists(atPath: options.manifestURL.path),
              artifactURLs.allSatisfy({
                  fileManager.fileExists(atPath: $0.path)
              }),
              fileManager.fileExists(atPath: options.generatedSourceURL.path),
              fileManager.fileExists(atPath: options.sourceMapURL.path),
              MojoRegularFile.isValid(at: options.manifestURL),
              MojoRegularFile.isValid(at: options.generatedSourceURL),
              MojoRegularFile.isValid(at: options.sourceMapURL) else {
            return nil
        }

        let manifest: MojoArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                MojoArtifactManifest.self,
                from: Data(contentsOf: options.manifestURL)
            )
        } catch {
            return nil
        }
        let sourceMapData = try Data(contentsOf: options.sourceMapURL)
        let sourceMapDigest = MojoCanonicalDigest.hex(sourceMapData)
        let generatedSourceDigest = try MojoCanonicalDigest.file(
            at: options.generatedSourceURL
        )
        let rendered = renderer.render(
            inputGraph: inputGraph,
            identity: options.identity
        )
        let expectedSourceMapData = try rendered.sourceMap.encode()
        guard manifest.schemaVersion == MojoArtifactManifest.currentSchemaVersion,
              manifest.abiVersion == MojoStaticABI.version,
              manifest.compilerVersion == compilerVersion,
              manifest.generationPipelineDigest == generationPipelineDigest,
              manifest.artifactIdentity == options.identity,
              manifest.effectiveSlices.map(\.target) == options.targets,
              manifest.sourceGraphDigest == inputGraph.bindingGraph.digest,
              manifest.sourceGraphIdentifier
                == inputGraph.bindingGraph.digestIdentifier,
              manifest.inputGraphDigest == inputGraph.digest,
              manifest.inputGraphIdentifier == inputGraph.digestIdentifier,
              manifest.generatedSourceDigest == generatedSourceDigest,
              generatedSourceDigest
                == MojoCanonicalDigest.hex(Data(rendered.source.utf8)),
              manifest.sourceMapDigest == sourceMapDigest,
              sourceMapData == expectedSourceMapData,
              manifest.externalPackages
                == inputGraph.externalPackages.map(\.manifestRecord),
              manifest.bindings
                == inputGraph.bindingGraph.bindings.map(
                    MojoArtifactManifest.Binding.init
                ) else {
            return nil
        }
        let expectedAdapters = Set(
            try options.targets.map(MojoNativeArtifactAdapter.init)
        )
        let artifacts = manifest.effectiveArtifacts
        guard artifacts.count == expectedAdapters.count,
              Set(artifacts.map(\.adapter)) == expectedAdapters,
              artifacts.allSatisfy({ artifact in
                  artifact.name
                      == artifact.adapter.artifactName(identity: options.identity)
              }),
              manifest.artifactDigest
                == MojoArtifactManifest.digest(artifacts: artifacts) else {
            return nil
        }
        for artifact in artifacts {
            let artifactURL = options.outputDirectoryURL.appendingPathComponent(
                artifact.name,
                isDirectory: true
            )
            let artifactSlices = try manifest.effectiveSlices.filter {
                try MojoNativeArtifactAdapter(target: $0.target)
                    == artifact.adapter
            }
            do {
                switch artifact.adapter {
                case .appleXCFramework:
                    try MojoXCFrameworkInspector.validate(
                        artifactURL: artifactURL,
                        identity: options.identity,
                        slices: artifactSlices
                    )
                case .linuxStaticLibraryBundle:
                    try MojoStaticLibraryArtifactBundleLayout.validate(
                        artifactURL: artifactURL,
                        identity: options.identity,
                        slices: artifactSlices
                    )
                }
                guard try MojoCanonicalDigest.tree(at: artifactURL)
                        == artifact.digest else {
                    return nil
                }
            } catch is MojoCanonicalDigestError {
                return nil
            } catch is MojoArtifactError {
                return nil
            }
        }
        guard try options.inputGraph() == inputGraph else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "artifact cache validation"
            )
        }
        return manifest
    }
}
