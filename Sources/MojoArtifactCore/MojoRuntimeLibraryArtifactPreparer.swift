import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeLibraryArtifactPreparer: Sendable {
    private let compiler: any MojoObjectCompiling
    private let receiptPreparer: MojoRuntimeReceiptPreparer
    private let bundleBuilder: MojoRuntimeLibraryBundleBuilder
    private let bundleVerifier: MojoRuntimeLibraryBundleVerifier
    private let renderer: MojoStaticSourceRenderer
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let runner = FoundationMojoProcessRunner(environment: environment)
        let inspector = MojoRuntimeBinaryInspector(
            processRunner: runner,
            environment: environment
        )
        let receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: inspector,
            processRunner: runner
        )
        let bundleVerifier = MojoRuntimeLibraryBundleVerifier(
            binaryInspector: inspector,
            processRunner: runner
        )
        try self.init(
            compiler: MojoCompiler(environment: environment),
            receiptPreparer: receiptPreparer,
            bundleBuilder: MojoRuntimeLibraryBundleBuilder(
                linker: MojoRuntimeLibraryLinker(
                    processRunner: runner,
                    environment: environment
                ),
                receiptVerifier: MojoRuntimeReceiptVerifier(
                    preparer: receiptPreparer
                ),
                bundleVerifier: bundleVerifier
            ),
            bundleVerifier: bundleVerifier
        )
    }

    package init(
        compiler: any MojoObjectCompiling,
        receiptPreparer: MojoRuntimeReceiptPreparer,
        bundleBuilder: MojoRuntimeLibraryBundleBuilder,
        bundleVerifier: MojoRuntimeLibraryBundleVerifier,
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.compiler = compiler
        self.receiptPreparer = receiptPreparer
        self.bundleBuilder = bundleBuilder
        self.bundleVerifier = bundleVerifier
        self.renderer = renderer
        self.transaction = transaction
    }

    package func prepare(
        options: MojoPrepareOptions,
        runtimeLibraryURLs: [URL],
        allowedSystemDependencies: Set<String> = []
    ) throws -> MojoRuntimeLibraryBundleManifest {
        guard options.targets.count == 1,
              let target = options.targets.first else {
            throw MojoArtifactError.invalidArguments(
                "A runtime library preparation requires exactly one target slice"
            )
        }
        guard target.accelerator != nil else {
            throw MojoArtifactError.invalidArguments(
                "A runtime library preparation requires an explicit accelerator target"
            )
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
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "swift-mojo-runtime-library-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: false
        )
        do {
            return try prepare(
                options: options,
                target: target,
                inputGraph: inputGraph,
                compilerVersion: compilerVersion,
                runtimeLibraryURLs: runtimeLibraryURLs,
                allowedSystemDependencies: allowedSystemDependencies,
                workingDirectory: workingDirectory
            )
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(
                    atPath: workingDirectory.path
                ) {
                    try FileManager.default.removeItem(at: workingDirectory)
                }
            } catch let cleanupError {
                throw MojoArtifactError.commandFailed(
                    command: "clean runtime library compilation directory",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                )
            }
            throw primaryError
        }
    }

    private func prepare(
        options: MojoPrepareOptions,
        target: MojoTargetConfiguration,
        inputGraph: MojoInputGraph,
        compilerVersion: String,
        runtimeLibraryURLs: [URL],
        allowedSystemDependencies: Set<String>,
        workingDirectory: URL
    ) throws -> MojoRuntimeLibraryBundleManifest {
        let rendered = renderer.render(
            inputGraph: inputGraph,
            identity: options.identity
        )
        let sourceURL = workingDirectory.appendingPathComponent(
            MojoStaticABI.generatedMojoSourceName
        )
        try rendered.source.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        let importRootURL = try MojoExternalPackageImportRoot.create(
            in: workingDirectory,
            externalPackages: inputGraph.externalPackages
        )
        let objectURL = workingDirectory.appendingPathComponent("Bindings.o")
        do {
            _ = try compiler.compileObject(
                inputPath: sourceURL.path,
                outputPath: objectURL.path,
                target: target,
                importSearchPaths: importRootURL.map { [$0.path] } ?? []
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
        let receiptOptions = try MojoRuntimeReceiptOptions(
            objectURL: objectURL,
            libraryURLs: runtimeLibraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )
        let receipt = try receiptPreparer.prepare(options: receiptOptions)
        let bundleOptions = try MojoRuntimeLibraryBundleOptions(
            outputDirectoryURL: options.outputDirectoryURL,
            identity: options.identity,
            compilerVersion: compilerVersion,
            inputGraph: inputGraph,
            objectURL: objectURL,
            libraryURLs: runtimeLibraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies,
            renderer: renderer
        )
        return try transaction.withExclusiveAccess(
            to: options.outputDirectoryURL
        ) { access in
            let staging = try transaction.makeStagingDirectory(
                for: options.outputDirectoryURL
            )
            do {
                let manifest = try bundleBuilder.prepareContents(
                    receipt: receipt,
                    options: bundleOptions,
                    staging: staging
                )
                try FileManager.default.removeItem(at: workingDirectory)
                guard try options.inputGraph() == inputGraph else {
                    throw MojoArtifactError.inputsChangedDuringOperation(
                        "runtime library preparation"
                    )
                }
                try transaction.commit(
                    stagingURL: staging,
                    outputURL: options.outputDirectoryURL,
                    access: access
                )
                let verified = try bundleVerifier.verify(
                    bundleURL: options.outputDirectoryURL
                )
                guard verified == manifest else {
                    throw MojoArtifactError.invalidRuntimeBundle(
                        "committed generated runtime library differs from its staged manifest"
                    )
                }
                return manifest
            } catch {
                let primaryError = error
                do {
                    if FileManager.default.fileExists(atPath: staging.path) {
                        try FileManager.default.removeItem(at: staging)
                    }
                } catch let cleanupError {
                    throw MojoArtifactError.commandFailed(
                        command: "clean generated runtime library staging directory",
                        status: -1,
                        diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                    )
                }
                throw primaryError
            }
        }
    }
}
