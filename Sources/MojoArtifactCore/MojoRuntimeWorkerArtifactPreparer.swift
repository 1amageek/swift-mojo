import Foundation
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerArtifactPreparer: Sendable {
    private let compiler: any MojoObjectCompiling
    private let workerCompiler: any MojoRuntimeWorkerCCompiling
    private let binaryInspector: any MojoRuntimeBinaryInspecting
    private let receiptPreparer: MojoRuntimeReceiptPreparer
    private let bundleBuilder: MojoRuntimeWorkerBundleBuilder
    private let bundleVerifier: MojoRuntimeWorkerBundleVerifier
    private let staticRenderer: MojoStaticSourceRenderer
    private let workerRenderer: MojoRuntimeWorkerRenderer
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let runner = FoundationMojoProcessRunner(environment: environment)
        let binaryInspector = MojoRuntimeBinaryInspector(
            processRunner: runner,
            environment: environment
        )
        let receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: binaryInspector,
            processRunner: runner
        )
        let runtimeVerifier = MojoRuntimeBundleVerifier(
            binaryInspector: binaryInspector,
            processRunner: runner
        )
        let workerVerifier = MojoRuntimeWorkerBundleVerifier(
            runtimeBundleVerifier: runtimeVerifier,
            binaryInspector: binaryInspector,
            processRunner: runner
        )
        try self.init(
            compiler: MojoCompiler(environment: environment),
            workerCompiler: MojoRuntimeWorkerCCompiler(
                processRunner: runner,
                environment: environment
            ),
            binaryInspector: binaryInspector,
            receiptPreparer: receiptPreparer,
            bundleBuilder: MojoRuntimeWorkerBundleBuilder(
                runtimeBundleBuilder: MojoRuntimeBundleBuilder(
                    linker: MojoRuntimeExecutableLinker(
                        processRunner: runner,
                        environment: environment
                    ),
                    receiptVerifier: MojoRuntimeReceiptVerifier(
                        preparer: receiptPreparer
                    ),
                    bundleVerifier: runtimeVerifier
                ),
                receiptVerifier: MojoRuntimeReceiptVerifier(
                    preparer: receiptPreparer
                ),
                binaryInspector: binaryInspector,
                workerVerifier: workerVerifier
            ),
            bundleVerifier: workerVerifier
        )
    }

    package init(
        compiler: any MojoObjectCompiling,
        workerCompiler: any MojoRuntimeWorkerCCompiling,
        binaryInspector: any MojoRuntimeBinaryInspecting,
        receiptPreparer: MojoRuntimeReceiptPreparer,
        bundleBuilder: MojoRuntimeWorkerBundleBuilder,
        bundleVerifier: MojoRuntimeWorkerBundleVerifier,
        staticRenderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        workerRenderer: MojoRuntimeWorkerRenderer = MojoRuntimeWorkerRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.compiler = compiler
        self.workerCompiler = workerCompiler
        self.binaryInspector = binaryInspector
        self.receiptPreparer = receiptPreparer
        self.bundleBuilder = bundleBuilder
        self.bundleVerifier = bundleVerifier
        self.staticRenderer = staticRenderer
        self.workerRenderer = workerRenderer
        self.transaction = transaction
    }

    package func prepare(
        options: MojoPrepareOptions,
        runtimeLibraryURLs: [URL],
        allowedSystemDependencies: Set<String> = [],
        executableName: String,
        maximumFramePayloadBytes: UInt64
    ) throws -> MojoRuntimeWorkerBundleManifest {
        guard options.targets.count == 1,
              let target = options.targets.first else {
            throw MojoArtifactError.invalidArguments(
                "A runtime worker preparation requires exactly one target slice"
            )
        }
        guard target.accelerator != nil else {
            throw MojoArtifactError.invalidArguments(
                "A runtime worker preparation requires an explicit accelerator target"
            )
        }
        _ = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
        try MojoRuntimeBundleOptions.validateExecutableName(executableName)
        guard !runtimeLibraryURLs.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "At least one --runtime-library path is required"
            )
        }
        let normalizedRuntimeLibraries = runtimeLibraryURLs.map(
            \.standardizedFileURL
        )
        guard Set(normalizedRuntimeLibraries.map(\.path)).count
                == normalizedRuntimeLibraries.count,
              Set(normalizedRuntimeLibraries.map(\.lastPathComponent)).count
                == normalizedRuntimeLibraries.count else {
            throw MojoArtifactError.invalidArguments(
                "Runtime library paths and filenames must be unique"
            )
        }
        for runtimeLibraryURL in normalizedRuntimeLibraries {
            try MojoRegularFile.validate(at: runtimeLibraryURL)
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
                "swift-mojo-runtime-worker-\(UUID().uuidString)",
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
                runtimeLibraryURLs: normalizedRuntimeLibraries,
                allowedSystemDependencies: allowedSystemDependencies,
                executableName: executableName,
                maximumFramePayloadBytes: maximumFramePayloadBytes,
                workingDirectory: workingDirectory
            )
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: workingDirectory.path) {
                    try FileManager.default.removeItem(at: workingDirectory)
                }
            } catch let cleanupError {
                throw MojoArtifactError.commandFailed(
                    command: "clean runtime worker compilation directory",
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
        executableName: String,
        maximumFramePayloadBytes: UInt64,
        workingDirectory: URL
    ) throws -> MojoRuntimeWorkerBundleManifest {
        let mojo = staticRenderer.render(
            inputGraph: inputGraph,
            identity: options.identity
        )
        let mojoSourceURL = workingDirectory.appendingPathComponent(
            MojoStaticABI.generatedMojoSourceName
        )
        try mojo.source.write(
            to: mojoSourceURL,
            atomically: true,
            encoding: .utf8
        )
        let importRootURL = try MojoExternalPackageImportRoot.create(
            in: workingDirectory,
            externalPackages: inputGraph.externalPackages
        )
        let mojoObjectURL = workingDirectory.appendingPathComponent("Bindings.o")
        do {
            _ = try compiler.compileObject(
                inputPath: mojoSourceURL.path,
                outputPath: mojoObjectURL.path,
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
                    diagnostic: mojo.sourceMap.remap(
                        diagnostic: diagnostic,
                        generatedSourcePath: mojoSourceURL.path
                    )
                )
            }
            throw error
        }
        try binaryInspector.validateObject(
            objectURL: mojoObjectURL,
            target: target
        )
        let receiptOptions = try MojoRuntimeReceiptOptions(
            objectURL: mojoObjectURL,
            libraryURLs: runtimeLibraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )
        let receipt = try receiptPreparer.prepare(options: receiptOptions)
        let mojoSourceDigest = try MojoCanonicalDigest.file(at: mojoSourceURL)
        let mojoObjectDigest = try MojoCanonicalDigest.file(at: mojoObjectURL)
        let rendered = try workerRenderer.render(
            inputGraph: inputGraph,
            identity: options.identity,
            target: target,
            compilerVersion: compilerVersion,
            generatedMojoSourceDigest: mojoSourceDigest,
            generatedMojoObjectDigest: mojoObjectDigest,
            receipt: receipt,
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
        guard rendered.mojo == mojo else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime worker Mojo rendering"
            )
        }

        let headerURL = workingDirectory.appendingPathComponent(
            "\(options.identity.moduleName).h"
        )
        let workerSourceURL = workingDirectory.appendingPathComponent(
            "RuntimeWorker.c"
        )
        try rendered.header.write(
            to: headerURL,
            atomically: true,
            encoding: .utf8
        )
        try rendered.workerSource.write(
            to: workerSourceURL,
            atomically: true,
            encoding: .utf8
        )
        let expectedHeaderDigest = MojoCanonicalDigest.hex(
            Data(rendered.header.utf8)
        )
        let expectedWorkerSourceDigest = rendered.workerSourceDigest
        let workerObjectURL = workingDirectory.appendingPathComponent(
            "RuntimeWorker.o"
        )
        try workerCompiler.compile(
            sourceURL: workerSourceURL,
            includeDirectoryURL: workingDirectory,
            outputURL: workerObjectURL,
            target: target
        )
        guard try MojoCanonicalDigest.file(at: headerURL)
                == expectedHeaderDigest,
              try MojoCanonicalDigest.file(at: workerSourceURL)
                == expectedWorkerSourceDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime worker C compilation"
            )
        }
        try binaryInspector.validateObject(
            objectURL: workerObjectURL,
            target: target
        )
        let bundleOptions = try MojoRuntimeWorkerBundleOptions(
            outputDirectoryURL: options.outputDirectoryURL,
            executableName: executableName,
            identity: options.identity,
            inputGraph: inputGraph,
            renderedSources: rendered,
            mojoSourceURL: mojoSourceURL,
            mojoObjectURL: mojoObjectURL,
            workerSourceURL: workerSourceURL,
            workerObjectURL: workerObjectURL,
            runtimeLibraryURLs: runtimeLibraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
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
                try bundleOptions.validateGeneratedInputs()
                guard try MojoCanonicalDigest.file(at: headerURL)
                        == expectedHeaderDigest else {
                    throw MojoArtifactError.inputsChangedDuringOperation(
                        "runtime worker header publication"
                    )
                }
                try FileManager.default.removeItem(at: workingDirectory)
                guard try options.inputGraph() == inputGraph else {
                    throw MojoArtifactError.inputsChangedDuringOperation(
                        "runtime worker preparation"
                    )
                }
                let verified = try transaction.commit(
                    stagingURL: staging,
                    outputURL: options.outputDirectoryURL,
                    access: access,
                    verification: { committedURL in
                        let committed = try bundleVerifier.verify(
                            bundleURL: committedURL
                        )
                        guard committed == manifest else {
                            throw MojoArtifactError.invalidRuntimeBundle(
                                "committed runtime worker bundle differs from its staged manifest"
                            )
                        }
                        return committed
                    }
                )
                return verified
            } catch {
                let primaryError = error
                do {
                    if FileManager.default.fileExists(atPath: staging.path) {
                        try FileManager.default.removeItem(at: staging)
                    }
                } catch let cleanupError {
                    throw MojoArtifactError.commandFailed(
                        command: "clean runtime worker bundle staging directory",
                        status: -1,
                        diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                    )
                }
                throw primaryError
            }
        }
    }
}
