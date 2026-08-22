import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeLibraryBundleBuilder: Sendable {
    private let linker: any MojoRuntimeLibraryLinking
    private let receiptVerifier: MojoRuntimeReceiptVerifier
    private let transaction: MojoOutputTransaction
    private let bundleVerifier: MojoRuntimeLibraryBundleVerifier

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
            linker: MojoRuntimeLibraryLinker(
                processRunner: runner,
                environment: environment
            ),
            receiptVerifier: MojoRuntimeReceiptVerifier(preparer: preparer),
            bundleVerifier: MojoRuntimeLibraryBundleVerifier(
                binaryInspector: inspector,
                processRunner: runner
            )
        )
    }

    package init(
        linker: any MojoRuntimeLibraryLinking,
        receiptVerifier: MojoRuntimeReceiptVerifier,
        bundleVerifier: MojoRuntimeLibraryBundleVerifier,
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.linker = linker
        self.receiptVerifier = receiptVerifier
        self.bundleVerifier = bundleVerifier
        self.transaction = transaction
    }

    package func prepare(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeLibraryBundleOptions
    ) throws -> MojoRuntimeLibraryBundleManifest {
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
                        "committed runtime library bundle differs from its staged manifest"
                    )
                }
                return manifest
            } catch {
                let primaryError = error
                do {
                    if FileManager.default.fileExists(atPath: staging.path) {
                        try FileManager.default.removeItem(at: staging)
                    }
                } catch {
                    throw MojoArtifactError.commandFailed(
                        command: "clean runtime library bundle staging directory",
                        status: -1,
                        diagnostic: "Primary error: \(primaryError); cleanup error: \(error)"
                    )
                }
                throw primaryError
            }
        }
    }

    package func prepareContents(
        receipt: MojoRuntimeDependencyReceipt,
        options: MojoRuntimeLibraryBundleOptions,
        staging: URL
    ) throws -> MojoRuntimeLibraryBundleManifest {
        _ = try receiptVerifier.verify(
            receipt: receipt,
            options: options.runtimeReceiptOptions
        )
        try MojoRuntimeLoaderPolicy.validate(receipt: receipt)
        let fileManager = FileManager.default
        let include = staging.appendingPathComponent(
            "include",
            isDirectory: true
        )
        let lib = staging.appendingPathComponent("lib", isDirectory: true)
        try fileManager.createDirectory(
            at: include,
            withIntermediateDirectories: false
        )
        try fileManager.createDirectory(
            at: lib,
            withIntermediateDirectories: false
        )
        let sources = Dictionary(
            uniqueKeysWithValues: options.libraryURLs.map {
                ($0.lastPathComponent, $0)
            }
        )
        let stagedRuntimeLibraries = try receipt.libraries.map {
            library -> URL in
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
                    "runtime library dependency staging"
                )
            }
            return destination
        }
        try receipt.encoded().write(
            to: staging.appendingPathComponent(
                MojoRuntimeLibraryBundleManifest.receiptFileName
            ),
            options: .atomic
        )
        let headerURL = include.appendingPathComponent(
            "\(options.identity.moduleName).h"
        )
        let moduleMapURL = include.appendingPathComponent("module.modulemap")
        try options.header.write(
            to: headerURL,
            atomically: true,
            encoding: .utf8
        )
        try options.moduleMap.write(
            to: moduleMapURL,
            atomically: true,
            encoding: .utf8
        )
        let primaryLibraryURL = lib.appendingPathComponent(
            options.primaryLibraryName
        )
        let originalObjectDigest = try MojoCanonicalDigest.file(
            at: options.objectURL
        )
        guard originalObjectDigest == receipt.objectDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime library linking"
            )
        }
        try linker.link(
            objectURL: options.objectURL,
            libraryURLs: stagedRuntimeLibraries,
            outputURL: primaryLibraryURL,
            target: options.target,
            systemDependencies: receipt.systemDependencies,
            exportedSymbols: options.exportedSymbols
        )
        guard try MojoCanonicalDigest.file(at: options.objectURL)
                == originalObjectDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "runtime library linking"
            )
        }
        try MojoRegularFile.validate(at: primaryLibraryURL)
        let inspection = try bundleVerifier.validateContents(
            receipt: receipt,
            primaryLibraryURL: primaryLibraryURL,
            runtimeLibraryURLs: stagedRuntimeLibraries,
            exportedSymbols: options.exportedSymbols
        )
        let manifest = MojoRuntimeLibraryBundleManifest(
            receiptDigest: receipt.digest,
            target: receipt.target,
            moduleName: options.identity.moduleName,
            compilerVersion: options.compilerVersion,
            inputGraphDigest: options.inputGraphDigest,
            inputGraphIdentifier: options.inputGraphIdentifier,
            generatedSourceDigest: options.generatedSourceDigest,
            sourceMapDigest: options.sourceMapDigest,
            loaderSearchPath: try MojoRuntimeLoaderPolicy
                .expectedLibrarySearchPath(target: receipt.target),
            library: .init(
                relativePath: "lib/\(options.primaryLibraryName)",
                digest: try MojoCanonicalDigest.file(at: primaryLibraryURL)
            ),
            runtimeLibraries: receipt.libraries.map {
                .init(
                    relativePath: "lib/\($0.fileName)",
                    digest: $0.digest
                )
            },
            interfaceHeader: .init(
                relativePath: "include/\(options.identity.moduleName).h",
                digest: try MojoCanonicalDigest.file(at: headerURL)
            ),
            moduleMap: .init(
                relativePath: "include/module.modulemap",
                digest: try MojoCanonicalDigest.file(at: moduleMapURL)
            ),
            exportedSymbols: options.exportedSymbols.sorted(),
            systemDependencies: MojoRuntimeLibraryBundleVerifier
                .systemDependencies(
                    inspection: inspection,
                    receipt: receipt
                )
        )
        try manifest.encoded().write(
            to: staging.appendingPathComponent(
                MojoRuntimeLibraryBundleManifest.fileName
            ),
            options: .atomic
        )
        let verified = try bundleVerifier.verify(bundleURL: staging)
        guard verified == manifest else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "staged runtime library bundle differs from its generated manifest"
            )
        }
        return manifest
    }
}
