import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoArtifactPreparer: Sendable {
    package static let packagingVersion = 1

    private let compiler: any MojoObjectCompiling
    private let generationPipelineDigest: String
    private let processRunner: any MojoProcessRunning
    private let renderer: MojoStaticSourceRenderer
    private let transaction: MojoOutputTransaction

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
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
        try Self.validate(target: options.target)
        let graph = try MojoSourceGraph(sourceURLs: options.sourceURLs)
        let compilerVersion = try compiler.compilerVersion()
        if let manifest = try cachedManifest(
            options: options,
            graph: graph,
            compilerVersion: compilerVersion
        ) {
            return MojoPrepareResult(
                manifest: manifest,
                disposition: .reused
            )
        }
        let staging = try transaction.makeStagingDirectory(
            for: options.outputDirectoryURL
        )
        do {
            let sourceURL = staging.appendingPathComponent("Bindings.mojo")
            let objectURL = staging.appendingPathComponent("Bindings.o")
            let archiveURL = staging.appendingPathComponent(
                MojoStaticABI.libraryName
            )
            let headersURL = staging.appendingPathComponent(
                "include",
                isDirectory: true
            )
            let artifactURL = staging.appendingPathComponent(
                MojoStaticABI.artifactName,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: headersURL,
                withIntermediateDirectories: true
            )
            try renderer.mojoSource(for: graph).write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
            try renderer.header.write(
                to: headersURL.appendingPathComponent("GeneratedMojoABI.h"),
                atomically: true,
                encoding: .utf8
            )
            try renderer.moduleMap.write(
                to: headersURL.appendingPathComponent("module.modulemap"),
                atomically: true,
                encoding: .utf8
            )

            _ = try compiler.compileObject(
                inputPath: sourceURL.path,
                outputPath: objectURL.path,
                target: options.target
            )
            try run(
                executablePath: "/usr/bin/ar",
                arguments: ["rcs", archiveURL.path, objectURL.path]
            )
            try run(
                executablePath: "/usr/bin/xcrun",
                arguments: [
                    "xcodebuild",
                    "-create-xcframework",
                    "-library", archiveURL.path,
                    "-headers", headersURL.path,
                    "-output", artifactURL.path,
                ]
            )

            let artifactDigest = try MojoCanonicalDigest.tree(at: artifactURL)
            let manifest = MojoArtifactManifest(
                compilerVersion: compilerVersion,
                target: options.target,
                sourceGraph: graph,
                artifactDigest: artifactDigest,
                generationPipelineDigest: generationPipelineDigest
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: staging.appendingPathComponent(MojoStaticABI.manifestName),
                options: .atomic
            )
            try FileManager.default.removeItem(at: objectURL)
            try transaction.commit(
                stagingURL: staging,
                outputURL: options.outputDirectoryURL,
                access: access
            )
            return MojoPrepareResult(
                manifest: manifest,
                disposition: .prepared
            )
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

    private func run(
        executablePath: String,
        arguments: [String]
    ) throws {
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

    private static func validate(target: MojoTargetConfiguration) throws {
        let normalized = target.triple.lowercased()
        guard normalized.hasPrefix("arm64-"),
              normalized.contains("apple-macos") else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    private func cachedManifest(
        options: MojoPrepareOptions,
        graph: MojoSourceGraph,
        compilerVersion: String
    ) throws -> MojoArtifactManifest? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.manifestURL.path),
              fileManager.fileExists(atPath: options.artifactURL.path) else {
            return nil
        }

        let manifest: MojoArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                MojoArtifactManifest.self,
                from: Data(contentsOf: options.manifestURL)
            )
        } catch {
            // Invalid cache metadata is repaired by a complete prepare transaction.
            return nil
        }
        guard manifest.schemaVersion == MojoArtifactManifest.currentSchemaVersion,
              manifest.abiVersion == MojoStaticABI.version,
              manifest.compilerVersion == compilerVersion,
              manifest.generationPipelineDigest == generationPipelineDigest,
              manifest.target == options.target,
              manifest.sourceGraphDigest == graph.digest,
              manifest.sourceGraphIdentifier == graph.digestIdentifier,
              manifest.bindings
                == graph.bindings.map(MojoArtifactManifest.Binding.init) else {
            return nil
        }
        let archives = try MojoArtifactVerifier.archiveURLs(in: options.artifactURL)
        guard archives.count == 1 else {
            return nil
        }
        let digest = try MojoCanonicalDigest.tree(at: options.artifactURL)
        return digest == manifest.artifactDigest ? manifest : nil
    }
}
