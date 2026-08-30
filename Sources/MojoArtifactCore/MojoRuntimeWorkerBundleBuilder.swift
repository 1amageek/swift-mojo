import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeWorkerBundleBuilder: Sendable {
    private static let forbiddenLoaderIdentifiers: Set<String> = [
        "dlopen", "dlsym", "dlclose",
    ]

    private let runtimeBundleBuilder: MojoRuntimeBundleBuilder
    private let receiptVerifier: MojoRuntimeReceiptVerifier
    private let binaryInspector: any MojoRuntimeBinaryInspecting
    private let workerVerifier: MojoRuntimeWorkerBundleVerifier
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
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
        self.init(
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
        )
    }

    package init(
        runtimeBundleBuilder: MojoRuntimeBundleBuilder,
        receiptVerifier: MojoRuntimeReceiptVerifier,
        binaryInspector: any MojoRuntimeBinaryInspecting,
        workerVerifier: MojoRuntimeWorkerBundleVerifier,
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.runtimeBundleBuilder = runtimeBundleBuilder
        self.receiptVerifier = receiptVerifier
        self.binaryInspector = binaryInspector
        self.workerVerifier = workerVerifier
        self.transaction = transaction
    }

    package func prepare(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeWorkerBundleOptions
    ) throws -> MojoRuntimeWorkerBundleManifest {
        try validateInputs(receipt: receipt, options: options)
        return try transaction.withExclusiveAccess(
            to: options.outputDirectoryURL
        ) { access in
            let staging = try transaction.makeStagingDirectory(
                for: options.outputDirectoryURL
            )
            do {
                let manifest = try prepareContents(
                    receipt: receipt,
                    options: options,
                    staging: staging
                )
                let verified = try transaction.commit(
                    stagingURL: staging,
                    outputURL: options.outputDirectoryURL,
                    access: access,
                    verification: { committedURL in
                        let committed = try workerVerifier.verify(
                            bundleURL: committedURL
                        )
                        guard committed == manifest else {
                            throw MojoArtifactError.invalidRuntimeBundle(
                                "committed worker bundle differs from its staged manifest"
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

    package func prepareContents(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeWorkerBundleOptions,
        staging: URL
    ) throws -> MojoRuntimeWorkerBundleManifest {
        try validateInputs(receipt: receipt, options: options)
        let runtimeManifest = try runtimeBundleBuilder.prepareContents(
            receipt: receipt,
            options: options.runtimeBundleOptions,
            additionalObjectURLs: [options.workerObjectURL],
            staging: staging
        )
        try options.validateGeneratedInputs()

        let semanticIdentity = try MojoRuntimeWorkerBundleManifest
            .SemanticIdentity(
                inputGraph: options.inputGraph,
                generationPipelineDigest: options.renderedSources
                    .executionContract.generationPipelineDigest,
                bindingTable: options.renderedSources.bindingTable
            )
        let generatedInputs = try MojoRuntimeWorkerBundleManifest
            .GeneratedInputs(
                generatedMojoSourceDigest: options.mojoSourceDigest,
                generatedCWorkerSourceDigest: options.workerSourceDigest,
                sourceMapDigest: options.renderedSources.executionContract
                    .sourceMapDigest,
                generatedMojoObjectDigest: options.mojoObjectDigest,
                generatedCWorkerObjectDigest: options.workerObjectDigest,
                compilerVersion: options.renderedSources.executionContract
                    .compilerIdentity
            )
        let protocolRecord = try MojoRuntimeWorkerBundleManifest.ProtocolRecord(
            maximumFramePayloadBytes: options.renderedSources.executionContract
                .maximumFramePayloadBytes
        )
        let runtimeRecord = try MojoRuntimeWorkerBundleManifest
            .RuntimeBundleRecord(
                manifestDigest: runtimeManifest.digest,
                manifest: runtimeManifest
            )
        let contractDigest = options.renderedSources.executionContract.digest
        let targetClosureDigest = try MojoRuntimeWorkerBundleManifest
            .targetClosureDigest(
                semanticIdentity: semanticIdentity,
                generatedInputs: generatedInputs,
                runtimeBundle: runtimeRecord,
                target: options.target,
                artifactIdentity: options.identity,
                executionContractDigest: contractDigest
            )
        let targetClosure = try MojoRuntimeWorkerBundleManifest.TargetClosure(
            target: options.target,
            artifactIdentity: options.identity,
            targetClosureDigest: targetClosureDigest
        )
        let manifest = try MojoRuntimeWorkerBundleManifest(
            semanticIdentity: semanticIdentity,
            generatedInputs: generatedInputs,
            protocolRecord: protocolRecord,
            runtimeBundle: runtimeRecord,
            targetClosure: targetClosure,
            executionContractDigest: contractDigest
        )
        try manifest.encoded().write(
            to: staging.appendingPathComponent(
                MojoRuntimeWorkerBundleManifest.fileName
            ),
            options: .atomic
        )
        let verified = try workerVerifier.verify(bundleURL: staging)
        guard verified == manifest else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "staged worker bundle differs from its generated manifest"
            )
        }
        return manifest
    }

    private func validateInputs(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeWorkerBundleOptions
    ) throws {
        try options.validateGeneratedInputs()
        _ = try receiptVerifier.verify(
            receipt: receipt,
            options: options.runtimeBundleOptions.runtimeReceiptOptions
        )
        try binaryInspector.validateObject(
            objectURL: options.workerObjectURL,
            target: options.target
        )
        try MojoRuntimeWorkerLibraryPolicy.validate(
            libraryURLs: options.libraryURLs,
            target: options.target,
            moduleName: options.identity.moduleName,
            symbolPrefix: options.identity.symbolPrefix,
            binaryInspector: binaryInspector
        )
        guard MojoRuntimeWorkerReceiptClosure(receipt)
                == options.renderedSources.executionContract.receiptClosure else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker execution contract does not match the runtime receipt"
            )
        }
        let identifierCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "_")
        )
        let generatedSources = [
            options.renderedSources.mojo.source,
            options.renderedSources.workerSource,
        ]
        let identifiers = Set(generatedSources.flatMap { source in
            source.components(separatedBy: identifierCharacters.inverted)
                .filter { !$0.isEmpty }
        })
        let forbidden = Self.forbiddenLoaderIdentifiers.intersection(identifiers)
        guard forbidden.isEmpty else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "generated worker sources reference forbidden loader identifiers: \(forbidden.sorted().joined(separator: ", "))"
            )
        }
    }
}
