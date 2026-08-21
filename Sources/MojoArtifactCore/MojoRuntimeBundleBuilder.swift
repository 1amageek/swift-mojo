import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeBundleBuilder: Sendable {
    private let linker: any MojoRuntimeExecutableLinking
    private let receiptVerifier: MojoRuntimeReceiptVerifier
    private let transaction: MojoOutputTransaction
    private let bundleVerifier: MojoRuntimeBundleVerifier

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let runner = FoundationMojoProcessRunner(environment: environment)
        let inspector = MojoRuntimeBinaryInspector(
            processRunner: runner,
            environment: environment
        )
        let preparer = MojoRuntimeReceiptPreparer(
            binaryInspector: inspector,
            processRunner: runner
        )
        self.init(
            linker: MojoRuntimeExecutableLinker(
                processRunner: runner,
                environment: environment
            ),
            receiptVerifier: MojoRuntimeReceiptVerifier(preparer: preparer),
            bundleVerifier: MojoRuntimeBundleVerifier(
                binaryInspector: inspector,
                processRunner: runner
            )
        )
    }

    package init(
        linker: any MojoRuntimeExecutableLinking,
        receiptVerifier: MojoRuntimeReceiptVerifier,
        bundleVerifier: MojoRuntimeBundleVerifier,
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.linker = linker
        self.receiptVerifier = receiptVerifier
        self.bundleVerifier = bundleVerifier
        self.transaction = transaction
    }

    package func prepare(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeBundleOptions
    ) throws -> MojoRuntimeBundleManifest {
        _ = try receiptVerifier.verify(
            receipt: receipt,
            options: options.runtimeReceiptOptions
        )
        try MojoRuntimeLoaderPolicy.validate(receipt: receipt)
        return try transaction.withExclusiveAccess(
            to: options.outputDirectoryURL
        ) { access in
            let staging = try transaction.makeStagingDirectory(
                for: options.outputDirectoryURL
            )
            do {
                let manifest = try prepare(
                    receipt: receipt,
                    options: options,
                    staging: staging
                )
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
                        "committed bundle differs from its staged manifest"
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
                        command: "clean runtime bundle staging directory",
                        status: -1,
                        diagnostic: "Primary error: \(primaryError); cleanup error: \(cleanupError)"
                    )
                }
                throw primaryError
            }
        }
    }

    private func prepare(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeBundleOptions,
        staging: URL
    ) throws -> MojoRuntimeBundleManifest {
        let fileManager = FileManager.default
        let bin = staging.appendingPathComponent("bin", isDirectory: true)
        let lib = staging.appendingPathComponent("lib", isDirectory: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: lib, withIntermediateDirectories: false)
        let sources = Dictionary(
            uniqueKeysWithValues: options.libraryURLs.map {
                ($0.lastPathComponent, $0)
            }
        )
        let stagedLibraries = try receipt.libraries.map { library -> URL in
            guard let source = sources[library.fileName] else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "missing source for runtime library '\(library.fileName)'"
                )
            }
            let destination = lib.appendingPathComponent(library.fileName)
            try fileManager.copyItem(at: source, to: destination)
            try MojoRegularFile.validate(at: destination)
            guard try MojoCanonicalDigest.file(at: destination)
                    == library.digest else {
                throw MojoArtifactError.inputsChangedDuringOperation(
                    "runtime library staging"
                )
            }
            return destination
        }
        try receipt.encoded().write(
            to: staging.appendingPathComponent(
                MojoRuntimeBundleManifest.receiptFileName
            ),
            options: .atomic
        )
        let executableURL = bin.appendingPathComponent(options.executableName)
        guard try MojoCanonicalDigest.file(at: options.objectURL)
                == receipt.objectDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime executable linking"
            )
        }
        try linker.link(
            objectURL: options.objectURL,
            libraryURLs: stagedLibraries,
            outputURL: executableURL,
            target: options.target,
            systemDependencies: receipt.systemDependencies
        )
        guard try MojoCanonicalDigest.file(at: options.objectURL)
                == receipt.objectDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime executable linking"
            )
        }
        try MojoRegularFile.validate(at: executableURL)
        let inspection = try bundleVerifier.validateContents(
            receipt: receipt,
            executableURL: executableURL,
            libraryURLs: stagedLibraries
        )
        let manifest = MojoRuntimeBundleManifest(
            receiptDigest: receipt.digest,
            target: receipt.target,
            loaderSearchPath: try MojoRuntimeLoaderPolicy.expectedSearchPath(
                target: receipt.target
            ),
            programInterpreter: inspection.programInterpreter,
            executable: MojoRuntimeBundleManifest.File(
                relativePath: "bin/\(options.executableName)",
                digest: try MojoCanonicalDigest.file(at: executableURL)
            ),
            libraries: receipt.libraries.map {
                MojoRuntimeBundleManifest.File(
                    relativePath: "lib/\($0.fileName)",
                    digest: $0.digest
                )
            },
            systemDependencies: MojoRuntimeBundleVerifier.systemDependencies(
                inspection: inspection,
                receipt: receipt
            )
        )
        try manifest.encoded().write(
            to: staging.appendingPathComponent(
                MojoRuntimeBundleManifest.fileName
            ),
            options: .atomic
        )
        let verified = try bundleVerifier.verify(bundleURL: staging)
        guard verified == manifest else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "staged bundle differs from its generated manifest"
            )
        }
        return manifest
    }
}
