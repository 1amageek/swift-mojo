import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoArtifactPreparer: Sendable {
    package static let packagingVersion = 4

    private let compiler: any MojoObjectCompiling
    private let generationPipelineDigest: String
    private let processRunner: any MojoProcessRunning
    private let renderer: MojoStaticSourceRenderer
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        try self.init(
            compiler: MojoCompiler(environment: environment),
            processRunner: FoundationMojoProcessRunner(environment: environment),
            generationPipelineDigest: MojoGenerationPipeline.digest
        )
    }

    package init(
        compiler: any MojoObjectCompiling,
        processRunner: any MojoProcessRunning,
        generationPipelineDigest: String = MojoGenerationPipeline.digest,
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.compiler = compiler
        self.generationPipelineDigest = generationPipelineDigest
        self.processRunner = processRunner
        self.renderer = renderer
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
            compilerVersion: compilerVersion
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

            let headersURL = staging.appendingPathComponent(
                ".headers",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: headersURL,
                withIntermediateDirectories: true
            )
            try renderer.header(identity: options.identity).write(
                to: headersURL.appendingPathComponent(
                    "\(options.identity.moduleName).h"
                ),
                atomically: true,
                encoding: .utf8
            )
            try renderer.moduleMap(identity: options.identity).write(
                to: headersURL.appendingPathComponent("module.modulemap"),
                atomically: true,
                encoding: .utf8
            )

            let buildURL = staging.appendingPathComponent(
                ".slices",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: buildURL,
                withIntermediateDirectories: true
            )
            let importRootURL = try Self.createImportRoot(
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
                try run(
                    executablePath: "/usr/bin/ar",
                    arguments: ["rcs", archiveURL.path, objectURL.path]
                )
                builtArchives.append(
                    (
                        target,
                        archiveURL
                    )
                )
            }

            let packagedArchives = try packageLibraries(
                builtArchives,
                in: staging,
                identity: options.identity
            )
            let artifactURL = staging.appendingPathComponent(
                options.identity.artifactName,
                isDirectory: true
            )
            var packagingArguments = ["xcodebuild", "-create-xcframework"]
            for archiveURL in packagedArchives {
                packagingArguments.append(
                    contentsOf: [
                        "-library", archiveURL.path,
                        "-headers", headersURL.path,
                    ]
                )
            }
            packagingArguments.append(contentsOf: ["-output", artifactURL.path])
            try run(
                executablePath: "/usr/bin/xcrun",
                arguments: packagingArguments
            )

            let slices = try MojoXCFrameworkInspector.resolveSlices(
                artifactURL: artifactURL,
                identity: options.identity,
                targets: options.targets
            )
            try MojoXCFrameworkInspector.validate(
                artifactURL: artifactURL,
                identity: options.identity,
                slices: slices
            )
            let artifactDigest = try MojoCanonicalDigest.tree(at: artifactURL)
            let manifest = MojoArtifactManifest(
                compilerVersion: compilerVersion,
                artifactIdentity: options.identity,
                inputGraph: inputGraph,
                slices: slices,
                generatedSourceDigest: MojoCanonicalDigest.hex(
                    generatedSourceData
                ),
                sourceMapDigest: MojoCanonicalDigest.hex(sourceMapData),
                artifactDigest: artifactDigest,
                generationPipelineDigest: generationPipelineDigest
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(MojoStaticABI.manifestName),
                options: .atomic
            )
            try FileManager.default.removeItem(at: headersURL)
            try FileManager.default.removeItem(at: buildURL)
            let libraryBuildURL = staging.appendingPathComponent(
                ".libraries",
                isDirectory: true
            )
            if FileManager.default.fileExists(atPath: libraryBuildURL.path) {
                try FileManager.default.removeItem(at: libraryBuildURL)
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

    private func packageLibraries(
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

    private static func createImportRoot(
        in stagingURL: URL,
        externalPackages: [MojoExternalPackage]
    ) throws -> URL? {
        guard !externalPackages.isEmpty else {
            return nil
        }
        let importRootURL = stagingURL.appendingPathComponent(
            ".imports",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: importRootURL,
            withIntermediateDirectories: false
        )
        for package in externalPackages {
            try FileManager.default.createSymbolicLink(
                at: importRootURL.appendingPathComponent(
                    package.name,
                    isDirectory: true
                ),
                withDestinationURL: package.rootURL
            )
        }
        return importRootURL
    }

    private static func validate(target: MojoTargetConfiguration) throws {
        let normalized = target.triple.lowercased()
        let supportedArchitecture = normalized.hasPrefix("arm64-")
            || normalized.hasPrefix("aarch64-")
            || normalized.hasPrefix("x86_64-")
        let supportedPlatform = normalized.contains("-apple-macos")
            || normalized.contains("-apple-ios")
        guard supportedArchitecture && supportedPlatform else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    private func cachedManifest(
        options: MojoPrepareOptions,
        inputGraph: MojoInputGraph,
        compilerVersion: String
    ) throws -> MojoArtifactManifest? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.manifestURL.path),
              fileManager.fileExists(atPath: options.artifactURL.path),
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
        let archives = try MojoArtifactVerifier.archiveURLs(
            in: options.artifactURL,
            identity: options.identity
        )
        let packagedLibraryCount = Set(
            manifest.effectiveSlices.map(\.libraryIdentifier)
        ).count
        guard archives.count == packagedLibraryCount else {
            return nil
        }
        let digest: String
        do {
            digest = try MojoCanonicalDigest.tree(at: options.artifactURL)
        } catch is MojoCanonicalDigestError {
            return nil
        }
        guard digest == manifest.artifactDigest else {
            return nil
        }
        guard try options.inputGraph() == inputGraph else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "artifact cache validation"
            )
        }
        return manifest
    }
}
