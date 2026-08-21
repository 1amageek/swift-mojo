import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoArtifactVerifier: Sendable {
    private let generationPipelineDigestOverride: String?
    private let registryWriter: MojoStaticRegistryWriter
    private let renderer: MojoStaticSourceRenderer
    private let transaction: MojoOutputTransaction

    package init(
        generationPipelineDigest: String? = nil,
        registryWriter: MojoStaticRegistryWriter = MojoStaticRegistryWriter(),
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.generationPipelineDigestOverride = generationPipelineDigest
        self.registryWriter = registryWriter
        self.renderer = renderer
        self.transaction = transaction
    }

    @discardableResult
    package func verify(options: MojoVerifyOptions) throws -> MojoArtifactManifest {
        try transaction.withExclusiveAccess(
            to: options.outputDirectoryURL
        ) { _ in
            let validation = try validateAssumingOutputLock(options: options)
            guard try options.inputGraph() == validation.inputGraph else {
                throw MojoArtifactError.inputsChangedDuringOperation(
                    "build verification"
                )
            }
            try FileManager.default.createDirectory(
                at: options.generatedSourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try registryWriter.source(
                manifest: validation.manifest,
                inputGraph: validation.inputGraph
            ).write(
                to: options.generatedSourceURL,
                atomically: true,
                encoding: .utf8
            )
            return validation.manifest
        }
    }

    package func validateAssumingOutputLock(
        options: MojoVerifyOptions
    ) throws -> MojoArtifactValidation {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.manifestURL.path) else {
            throw MojoArtifactError.manifestMissing(options.manifestURL.path)
        }
        try MojoRegularFile.validate(at: options.manifestURL)

        let manifest: MojoArtifactManifest
        do {
            manifest = try JSONDecoder().decode(
                MojoArtifactManifest.self,
                from: Data(contentsOf: options.manifestURL)
            )
        } catch {
            throw MojoArtifactError.invalidManifest(String(describing: error))
        }
        try validateSchemaAndABI(manifest: manifest)

        let identity = manifest.effectiveIdentity
        if let expectedIdentity = options.expectedIdentity,
           identity != expectedIdentity {
            throw MojoArtifactError.artifactIdentityMismatch(
                expected: expectedIdentity.moduleName,
                actual: identity.moduleName
            )
        }
        if let expectedCompilerVersion = options.expectedCompilerVersion,
           manifest.compilerVersion != expectedCompilerVersion {
            throw MojoArtifactError.compilerVersionMismatch(
                expected: expectedCompilerVersion,
                actual: manifest.compilerVersion
            )
        }
        if let expectedSlices = options.expectedSlices {
            let actualSlices = manifest.effectiveSlices.map(\.target).sorted {
                $0.identity < $1.identity
            }
            guard actualSlices == expectedSlices else {
                throw MojoArtifactError.releaseSliceMismatch(
                    expected: expectedSlices.map(\.identity).joined(
                        separator: ", "
                    ),
                    actual: actualSlices.map(\.identity).joined(
                        separator: ", "
                    )
                )
            }
        }
        try validateTarget(manifest: manifest, requested: options.target)
        try validateArtifactContract(manifest: manifest, identity: identity)

        let inputGraph = try options.inputGraph()
        try validatePipeline(manifest: manifest, inputGraph: inputGraph)
        try validateGraph(manifest: manifest, inputGraph: inputGraph)
        try validateGeneratedSources(
            manifest: manifest,
            inputGraph: inputGraph,
            preparedSourceURL: options.preparedSourceURL,
            sourceMapURL: options.sourceMapURL
        )
        for artifact in manifest.effectiveArtifacts {
            let artifactURL = options.outputDirectoryURL.appendingPathComponent(
                artifact.name,
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw MojoArtifactError.artifactMissing(artifactURL.path)
            }
            let slices = try manifest.effectiveSlices.filter {
                try MojoNativeArtifactAdapter(target: $0.target)
                    == artifact.adapter
            }
            try validateArtifact(
                manifest: manifest,
                artifact: artifact,
                artifactURL: artifactURL,
                identity: identity,
                slices: slices
            )
        }
        return MojoArtifactValidation(
            manifest: manifest,
            inputGraph: inputGraph
        )
    }

    private func validateSchemaAndABI(
        manifest: MojoArtifactManifest
    ) throws {
        let supportedSchema = manifest.schemaVersion
            == MojoArtifactManifest.currentSchemaVersion
            || manifest.schemaVersion
                == MojoArtifactManifest.appleSchemaVersion
            || manifest.schemaVersion
                == MojoArtifactManifest.legacySchemaVersion
        guard supportedSchema else {
            throw MojoArtifactError.invalidManifest(
                "unsupported schema version \(manifest.schemaVersion)"
            )
        }
        guard manifest.abiVersion == MojoStaticABI.version else {
            throw MojoArtifactError.invalidManifest(
                "unsupported ABI version \(manifest.abiVersion)"
            )
        }
    }

    private func validatePipeline(
        manifest: MojoArtifactManifest,
        inputGraph: MojoInputGraph
    ) throws {
        let expectedPipeline = manifest.schemaVersion
            == MojoArtifactManifest.legacySchemaVersion
            ? MojoGenerationPipeline.legacyDigest
            : generationPipelineDigestOverride
                ?? MojoGenerationPipeline.digest(for: inputGraph)
        guard manifest.generationPipelineDigest == expectedPipeline else {
            throw MojoArtifactError.generationPipelineMismatch(
                expected: expectedPipeline,
                actual: manifest.generationPipelineDigest
            )
        }
    }

    private func validateTarget(
        manifest: MojoArtifactManifest,
        requested: MojoTargetConfiguration?
    ) throws {
        guard let requested else {
            return
        }
        if manifest.schemaVersion == MojoArtifactManifest.legacySchemaVersion {
            guard let prepared = manifest.target,
                  prepared == requested else {
                let prepared = manifest.target
                throw MojoArtifactError.targetMismatch(
                    expectedTriple: prepared?.triple ?? "missing",
                    expectedCPU: prepared?.cpu ?? "missing",
                    actualTriple: requested.triple,
                    actualCPU: requested.cpu
                )
            }
            return
        }
        guard manifest.effectiveSlices.contains(where: {
            $0.target == requested
        }) else {
            let prepared = manifest.effectiveSlices
                .map(\.target.identity).joined(separator: ", ")
            throw MojoArtifactError.targetSliceMissing(
                requested: requested.identity,
                prepared: prepared
            )
        }
    }

    private func validateGraph(
        manifest: MojoArtifactManifest,
        inputGraph: MojoInputGraph
    ) throws {
        guard manifest.sourceGraphDigest == inputGraph.bindingGraph.digest,
              manifest.sourceGraphIdentifier
                == inputGraph.bindingGraph.digestIdentifier else {
            throw MojoArtifactError.sourceGraphMismatch(
                expected: manifest.sourceGraphDigest,
                actual: inputGraph.bindingGraph.digest
            )
        }
        guard manifest.bindings
                == inputGraph.bindingGraph.bindings.map(
                    MojoArtifactManifest.Binding.init
                ) else {
            throw MojoArtifactError.bindingGraphMismatch
        }
        if manifest.supportsInputGraph {
            guard manifest.inputGraphDigest == inputGraph.digest,
                  manifest.inputGraphIdentifier == inputGraph.digestIdentifier,
                  manifest.externalPackages
                    == inputGraph.externalPackages.map(\.manifestRecord) else {
                throw MojoArtifactError.inputGraphMismatch(
                    expected: manifest.inputGraphDigest ?? "missing",
                    actual: inputGraph.digest
                )
            }
        } else if !inputGraph.externalPackages.isEmpty {
            throw MojoArtifactError.invalidManifest(
                "schema-3 artifacts cannot verify external Mojo packages"
            )
        }
    }

    private func validateGeneratedSources(
        manifest: MojoArtifactManifest,
        inputGraph: MojoInputGraph,
        preparedSourceURL: URL,
        sourceMapURL: URL
    ) throws {
        guard manifest.supportsInputGraph else {
            return
        }
        guard FileManager.default.fileExists(atPath: preparedSourceURL.path) else {
            throw MojoArtifactError.generatedSourceMissing(
                preparedSourceURL.path
            )
        }
        guard FileManager.default.fileExists(atPath: sourceMapURL.path) else {
            throw MojoArtifactError.sourceMapMissing(sourceMapURL.path)
        }
        try MojoRegularFile.validate(at: preparedSourceURL)
        try MojoRegularFile.validate(at: sourceMapURL)
        let sourceData = try Data(contentsOf: preparedSourceURL)
        let data = try Data(contentsOf: sourceMapURL)
        let sourceMap: MojoSourceMap
        do {
            sourceMap = try JSONDecoder().decode(MojoSourceMap.self, from: data)
        } catch {
            throw MojoArtifactError.invalidManifest(
                "source map decode failed: \(error)"
            )
        }
        let expected = renderer.render(
            inputGraph: inputGraph,
            identity: manifest.effectiveIdentity
        )
        let expectedSourceData = Data(expected.source.utf8)
        let expectedSourceMapData = try expected.sourceMap.encode()
        let sourceDigest = MojoCanonicalDigest.hex(sourceData)
        let digest = MojoCanonicalDigest.hex(data)
        guard manifest.generatedSourceDigest == sourceDigest,
              sourceData == expectedSourceData else {
            throw MojoArtifactError.generatedSourceMismatch(
                expected: manifest.generatedSourceDigest ?? "missing",
                actual: sourceDigest
            )
        }
        guard manifest.sourceMapDigest == digest,
              sourceMap.schemaVersion == MojoSourceMap.currentSchemaVersion,
              sourceMap.inputGraphDigest == inputGraph.digest,
              data == expectedSourceMapData else {
            throw MojoArtifactError.sourceMapMismatch(
                expected: manifest.sourceMapDigest ?? "missing",
                actual: digest
            )
        }
    }

    private func validateArtifactContract(
        manifest: MojoArtifactManifest,
        identity: MojoArtifactIdentity
    ) throws {
        guard manifest.schemaVersion == MojoArtifactManifest.currentSchemaVersion else {
            return
        }
        guard let artifacts = manifest.artifacts,
              !artifacts.isEmpty,
              Set(artifacts.map(\.adapter)).count == artifacts.count,
              Set(artifacts.map(\.name)).count == artifacts.count,
              artifacts.allSatisfy({ artifact in
                  artifact.name
                      == artifact.adapter.artifactName(identity: identity)
              }),
              manifest.artifactDigest
                == MojoArtifactManifest.digest(artifacts: artifacts) else {
            throw MojoArtifactError.invalidManifest(
                "schema-5 native artifact records are missing, duplicated, or inconsistent"
            )
        }
        let sliceAdapters = Set(
            try manifest.effectiveSlices.map {
                try MojoNativeArtifactAdapter(target: $0.target)
            }
        )
        guard sliceAdapters == Set(artifacts.map(\.adapter)) else {
            throw MojoArtifactError.invalidManifest(
                "schema-5 native artifact records do not cover every prepared slice"
            )
        }
    }

    private func validateArtifact(
        manifest: MojoArtifactManifest,
        artifact: MojoArtifactManifest.Artifact,
        artifactURL: URL,
        identity: MojoArtifactIdentity,
        slices: [MojoArtifactManifest.Slice]
    ) throws {
        switch artifact.adapter {
        case .appleXCFramework:
            let archives = try Self.archiveURLs(
                in: artifactURL,
                identity: identity
            )
            let packagedLibraryCount = Set(slices.map(\.libraryIdentifier)).count
            guard archives.count == packagedLibraryCount else {
                throw MojoArtifactError.artifactArchiveCount(archives.count)
            }
            if manifest.supportsInputGraph {
                let infoPlist = artifactURL.appendingPathComponent("Info.plist")
                guard FileManager.default.fileExists(atPath: infoPlist.path) else {
                    throw MojoArtifactError.artifactInterfaceMissing(infoPlist.path)
                }
                for slice in slices {
                    let sliceURL = artifactURL
                        .appendingPathComponent(
                            slice.libraryIdentifier,
                            isDirectory: true
                        )
                    let frameworkURL = MojoStaticFrameworkLayout.frameworkURL(
                        in: sliceURL,
                        identity: identity
                    )
                    let archiveURL = MojoStaticFrameworkLayout.binaryURL(
                        in: sliceURL,
                        identity: identity
                    )
                    guard FileManager.default.fileExists(
                        atPath: archiveURL.path
                    ) else {
                        throw MojoArtifactError.sliceArchiveMissing(
                            slice.target.identity
                        )
                    }
                    let digest = try MojoCanonicalDigest.file(at: archiveURL)
                    guard digest == slice.archiveDigest else {
                        throw MojoArtifactError.sliceArchiveDigestMismatch(
                            target: slice.target.identity,
                            expected: slice.archiveDigest,
                            actual: digest
                        )
                    }
                    let headersURL = MojoStaticFrameworkLayout.headersURL(
                        in: frameworkURL
                    )
                    let modulesURL = MojoStaticFrameworkLayout.modulesURL(
                        in: frameworkURL
                    )
                    for required in [
                        modulesURL.appendingPathComponent("module.modulemap"),
                        headersURL.appendingPathComponent(
                            "\(identity.moduleName).h"
                        ),
                        frameworkURL.appendingPathComponent("Info.plist"),
                    ] where !FileManager.default.fileExists(
                        atPath: required.path
                    ) {
                        throw MojoArtifactError.artifactInterfaceMissing(
                            required.path
                        )
                    }
                }
                try MojoXCFrameworkInspector.validate(
                    artifactURL: artifactURL,
                    identity: identity,
                    slices: slices
                )
            }
        case .linuxStaticLibraryBundle:
            guard manifest.schemaVersion
                    == MojoArtifactManifest.currentSchemaVersion else {
                throw MojoArtifactError.invalidManifest(
                    "Linux static-library artifacts require schema 5"
                )
            }
            try MojoStaticLibraryArtifactBundleLayout.validate(
                artifactURL: artifactURL,
                identity: identity,
                slices: slices
            )
        }
        let digest = try MojoCanonicalDigest.tree(at: artifactURL)
        guard digest == artifact.digest else {
            throw MojoArtifactError.artifactDigestMismatch(
                expected: artifact.digest,
                actual: digest
            )
        }
    }

    package static func archiveURLs(
        in artifactURL: URL,
        identity: MojoArtifactIdentity = .legacy
    ) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: artifactURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator
        where url.lastPathComponent == identity.libraryName
            || url.lastPathComponent == identity.moduleName {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }
}
