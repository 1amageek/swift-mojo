import Foundation
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerBundleVerifier: Sendable {
    private static let forbiddenLoaderSymbols: Set<String> = [
        "dlopen", "dlsym", "dlclose",
    ]

    private let runtimeBundleVerifier: MojoRuntimeBundleVerifier
    private let binaryInspector: any MojoRuntimeBinaryInspecting
    private let linkageInspector: MojoObjectLinkageInspector
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let runner = FoundationMojoProcessRunner(environment: environment)
        let binaryInspector = MojoRuntimeBinaryInspector(
            processRunner: runner,
            environment: environment
        )
        self.init(
            runtimeBundleVerifier: MojoRuntimeBundleVerifier(
                binaryInspector: binaryInspector,
                processRunner: runner
            ),
            binaryInspector: binaryInspector,
            processRunner: runner
        )
    }

    package init(
        runtimeBundleVerifier: MojoRuntimeBundleVerifier,
        binaryInspector: any MojoRuntimeBinaryInspecting,
        processRunner: any MojoProcessRunning,
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.runtimeBundleVerifier = runtimeBundleVerifier
        self.binaryInspector = binaryInspector
        self.linkageInspector = MojoObjectLinkageInspector(
            processRunner: processRunner
        )
        self.transaction = transaction
    }

    package func verify(
        bundleURL: URL
    ) throws -> MojoRuntimeWorkerBundleManifest {
        let root = bundleURL.standardizedFileURL
        guard transaction.isManaged(root) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker bundle is not a managed swift-mojo output at '\(root.path)'"
            )
        }
        try MojoRuntimeBundleVerifier.validateDirectory(root)

        let workerManifestURL = root.appendingPathComponent(
            MojoRuntimeWorkerBundleManifest.fileName
        )
        let runtimeManifestURL = root.appendingPathComponent(
            MojoRuntimeBundleManifest.fileName
        )
        let receiptURL = root.appendingPathComponent(
            MojoRuntimeBundleManifest.receiptFileName
        )
        for url in [workerManifestURL, runtimeManifestURL, receiptURL] {
            try MojoRegularFile.validate(at: url)
        }
        let workerManifest = try MojoRuntimeWorkerBundleManifest.decode(
            Data(contentsOf: workerManifestURL, options: .mappedIfSafe)
        )
        let runtimeManifest = try MojoRuntimeBundleManifest.decode(
            Data(contentsOf: runtimeManifestURL, options: .mappedIfSafe)
        )
        let receipt = try MojoRuntimeDependencyReceipt.decode(
            Data(contentsOf: receiptURL, options: .mappedIfSafe)
        )

        let executableName = runtimeManifest.executable.relativePath
            .split(separator: "/").last.map(String.init) ?? ""
        try validateLayout(
            root: root,
            executableName: executableName,
            libraryNames: receipt.libraries.map(\.fileName)
        )
        try runtimeBundleVerifier.validateManifestContents(
            bundleURL: root,
            manifest: runtimeManifest,
            receipt: receipt
        )
        try MojoRuntimeWorkerLibraryPolicy.validate(
            libraryURLs: receipt.libraries.map {
                root.appendingPathComponent("lib/\($0.fileName)")
            },
            target: receipt.target,
            moduleName: workerManifest.targetClosure.artifactIdentity
                .moduleName,
            symbolPrefix: workerManifest.targetClosure.artifactIdentity
                .symbolPrefix,
            binaryInspector: binaryInspector
        )

        let expectedRuntimeRecord = try MojoRuntimeWorkerBundleManifest
            .RuntimeBundleRecord(
                manifestDigest: runtimeManifest.digest,
                manifest: runtimeManifest
            )
        guard workerManifest.runtimeBundle == expectedRuntimeRecord else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker runtime-bundle record does not match RuntimeBundle.json"
            )
        }

        let target = try workerManifest.targetClosure.target
        guard target == runtimeManifest.target,
              target == receipt.target else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker target closure does not match the executable runtime closure"
            )
        }
        let expectedProtocol = try MojoRuntimeWorkerBundleManifest
            .ProtocolRecord(
                maximumFramePayloadBytes: workerManifest.protocolRecord
                    .maximumFramePayloadBytes
            )
        guard workerManifest.protocolRecord == expectedProtocol else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker protocol record is not canonical"
            )
        }
        let bindingTable = try workerManifest.semanticIdentity.bindingTable
        let executionContract = try MojoRuntimeWorkerExecutionContract(
            workerABIVersion: workerManifest.semanticIdentity.workerABIVersion,
            inputGraphDigest: workerManifest.semanticIdentity.inputGraphDigest,
            inputGraphIdentifier: workerManifest.semanticIdentity
                .inputGraphIdentifier,
            bindingTable: bindingTable,
            target: target,
            generationPipelineDigest: workerManifest.semanticIdentity
                .generationPipelineDigest,
            compilerIdentity: workerManifest.generatedInputs.compilerVersion,
            sourceMapDigest: workerManifest.generatedInputs.sourceMapDigest,
            generatedMojoSourceDigest: workerManifest.generatedInputs
                .generatedMojoSourceDigest,
            generatedMojoObjectDigest: workerManifest.generatedInputs
                .generatedMojoObjectDigest,
            maximumFramePayloadBytes: workerManifest.protocolRecord
                .maximumFramePayloadBytes,
            receiptClosure: MojoRuntimeWorkerReceiptClosure(receipt)
        )
        guard executionContract.digest
                == workerManifest.executionContractDigest else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker execution contract digest is inconsistent"
            )
        }

        let executableURL = root.appendingPathComponent(
            runtimeManifest.executable.relativePath
        )
        let undefinedSymbols = try linkageInspector.undefinedSymbols(
            objectURL: executableURL,
            target: target
        )
        let forbidden = Self.forbiddenLoaderSymbols.intersection(
            undefinedSymbols
        )
        guard forbidden.isEmpty else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "worker executable imports forbidden loader symbols: \(forbidden.sorted().joined(separator: ", "))"
            )
        }
        return workerManifest
    }

    private func validateLayout(
        root: URL,
        executableName: String,
        libraryNames: [String]
    ) throws {
        try MojoRuntimeBundleVerifier.validateEntries(
            directory: root,
            expected: [
                MojoOutputTransaction.markerName,
                MojoRuntimeBundleManifest.fileName,
                MojoRuntimeBundleManifest.receiptFileName,
                MojoRuntimeWorkerBundleManifest.fileName,
                "bin",
                "lib",
            ]
        )
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try MojoRuntimeBundleVerifier.validateDirectory(bin)
        try MojoRuntimeBundleVerifier.validateDirectory(lib)
        try MojoRuntimeBundleVerifier.validateEntries(
            directory: bin,
            expected: [executableName]
        )
        try MojoRuntimeBundleVerifier.validateEntries(
            directory: lib,
            expected: Set(libraryNames)
        )
    }
}
