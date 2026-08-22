import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeLibraryBundleVerifier: Sendable {
    private let binaryInspector: any MojoRuntimeBinaryInspecting
    private let receiptPreparer: MojoRuntimeReceiptPreparer
    private let transaction: MojoOutputTransaction

    package init(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let runner = FoundationMojoProcessRunner(environment: environment)
        let inspector = MojoRuntimeBinaryInspector(
            processRunner: runner,
            environment: environment
        )
        self.init(
            binaryInspector: inspector,
            processRunner: runner
        )
    }

    package init(
        binaryInspector: any MojoRuntimeBinaryInspecting,
        processRunner: any MojoProcessRunning,
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.binaryInspector = binaryInspector
        self.receiptPreparer = MojoRuntimeReceiptPreparer(
            binaryInspector: binaryInspector,
            processRunner: processRunner
        )
        self.transaction = transaction
    }

    package func verify(
        bundleURL: URL
    ) throws -> MojoRuntimeLibraryBundleManifest {
        let root = bundleURL.standardizedFileURL
        guard transaction.isManaged(root) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime library bundle is not a managed swift-mojo output at '\(root.path)'"
            )
        }
        try Self.validateDirectory(root)
        let manifestURL = root.appendingPathComponent(
            MojoRuntimeLibraryBundleManifest.fileName
        )
        let receiptURL = root.appendingPathComponent(
            MojoRuntimeLibraryBundleManifest.receiptFileName
        )
        try MojoRegularFile.validate(at: manifestURL)
        try MojoRegularFile.validate(at: receiptURL)
        let manifest = try MojoRuntimeLibraryBundleManifest.decode(
            Data(contentsOf: manifestURL)
        )
        let receipt = try MojoRuntimeDependencyReceipt.decode(
            Data(contentsOf: receiptURL)
        )
        guard manifest.receiptDigest == receipt.digest,
              manifest.target == receipt.target else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime library manifest and receipt identities do not match"
            )
        }
        let primaryName = URL(fileURLWithPath: manifest.library.relativePath)
            .lastPathComponent
        guard manifest.library.relativePath == "lib/\(primaryName)",
              !primaryName.isEmpty,
              !receipt.libraries.contains(where: {
                  $0.fileName == primaryName
              }) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "primary runtime library path is invalid or conflicts with a dependency"
            )
        }
        let expectedRuntimeLibraries = receipt.libraries.map {
            MojoRuntimeLibraryBundleManifest.File(
                relativePath: "lib/\($0.fileName)",
                digest: $0.digest
            )
        }
        guard manifest.runtimeLibraries == expectedRuntimeLibraries,
              MojoRuntimeLoaderPolicy.isPortableCSymbol(
                manifest.moduleName
              ),
              !manifest.compilerVersion.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty,
              Self.isSHA256Digest(manifest.inputGraphDigest),
              Self.isSHA256Digest(manifest.generatedSourceDigest),
              Self.isSHA256Digest(manifest.sourceMapDigest),
              manifest.interfaceHeader.relativePath
                == "include/\(manifest.moduleName).h",
              manifest.moduleMap.relativePath == "include/module.modulemap",
              !manifest.exportedSymbols.isEmpty,
              Set(manifest.exportedSymbols).count
                == manifest.exportedSymbols.count,
              manifest.exportedSymbols.allSatisfy(
                MojoRuntimeLoaderPolicy.isPortableCSymbol
              ) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime library files or declared ABI metadata are inconsistent"
            )
        }
        try validateLayout(
            root: root,
            primaryName: primaryName,
            moduleName: manifest.moduleName,
            runtimeLibraryNames: receipt.libraries.map(\.fileName)
        )
        let primaryURL = root.appendingPathComponent(
            manifest.library.relativePath
        )
        let runtimeLibraryURLs = receipt.libraries.map {
            root.appendingPathComponent("lib/\($0.fileName)")
        }
        let headerURL = root.appendingPathComponent(
            manifest.interfaceHeader.relativePath
        )
        let moduleMapURL = root.appendingPathComponent(
            manifest.moduleMap.relativePath
        )
        for (record, url) in [
            (manifest.library, primaryURL),
            (manifest.interfaceHeader, headerURL),
            (manifest.moduleMap, moduleMapURL),
        ] + Array(zip(manifest.runtimeLibraries, runtimeLibraryURLs)) {
            try MojoRegularFile.validate(at: url)
            guard try MojoCanonicalDigest.file(at: url) == record.digest else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "runtime library bundle digest does not match for '\(record.relativePath)'"
                )
            }
        }
        let inspection = try validateContents(
            receipt: receipt,
            primaryLibraryURL: primaryURL,
            runtimeLibraryURLs: runtimeLibraryURLs,
            exportedSymbols: Set(manifest.exportedSymbols)
        )
        let expectedLoaderSearchPath = try MojoRuntimeLoaderPolicy
            .expectedLibrarySearchPath(target: receipt.target)
        guard manifest.loaderSearchPath == expectedLoaderSearchPath,
              manifest.systemDependencies
                == Self.systemDependencies(
                    inspection: inspection,
                    receipt: receipt
                ) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime library manifest loader metadata does not match the linked binary"
            )
        }
        return manifest
    }

    package func validateContents(
        receipt: MojoRuntimeDependencyReceipt,
        primaryLibraryURL: URL,
        runtimeLibraryURLs: [URL],
        exportedSymbols: Set<String>
    ) throws -> MojoRuntimeBinaryInspection {
        try MojoRuntimeLoaderPolicy.validate(receipt: receipt)
        let allowedSystemDependencies: Set<String>
        if receipt.target.triple.lowercased().contains("-linux-") {
            allowedSystemDependencies = Set(receipt.systemDependencies)
        } else {
            allowedSystemDependencies = []
        }
        let current = try receiptPreparer.prepare(
            options: MojoRuntimeReceiptOptions(
                objectURL: primaryLibraryURL,
                libraryURLs: runtimeLibraryURLs,
                target: receipt.target,
                allowedSystemDependencies: allowedSystemDependencies
            )
        )
        guard current.linkagePolicyVersion == receipt.linkagePolicyVersion,
              current.target == receipt.target,
              current.requiredSymbols == receipt.requiredSymbols,
              current.systemDependencies == receipt.systemDependencies,
              current.libraries == receipt.libraries else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "linked library does not reproduce the receipt runtime closure"
            )
        }
        let inspection = try binaryInspector.inspect(
            libraryURL: primaryLibraryURL,
            target: receipt.target
        )
        try MojoRuntimeLoaderPolicy.validate(
            linkedLibrary: inspection,
            receipt: receipt,
            libraryName: primaryLibraryURL.lastPathComponent,
            exportedSymbols: exportedSymbols
        )
        return inspection
    }

    package static func systemDependencies(
        inspection: MojoRuntimeBinaryInspection,
        receipt: MojoRuntimeDependencyReceipt
    ) -> [String] {
        let runtime = Set(receipt.libraries.map(\.installName))
        return inspection.dynamicDependencies.filter {
            !runtime.contains($0)
        }.sorted()
    }

    private func validateLayout(
        root: URL,
        primaryName: String,
        moduleName: String,
        runtimeLibraryNames: [String]
    ) throws {
        try Self.validateEntries(
            directory: root,
            expected: [
                MojoOutputTransaction.markerName,
                MojoRuntimeLibraryBundleManifest.fileName,
                MojoRuntimeLibraryBundleManifest.receiptFileName,
                "include",
                "lib",
            ]
        )
        let include = root.appendingPathComponent("include", isDirectory: true)
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try Self.validateDirectory(include)
        try Self.validateDirectory(lib)
        try Self.validateEntries(
            directory: include,
            expected: ["\(moduleName).h", "module.modulemap"]
        )
        try Self.validateEntries(
            directory: lib,
            expected: Set([primaryName] + runtimeLibraryNames)
        )
    }

    private static func validateEntries(
        directory: URL,
        expected: Set<String>
    ) throws {
        let actual = Set(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        guard actual == expected else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "directory '\(directory.path)' contains [\(actual.sorted().joined(separator: ", "))], expected [\(expected.sorted().joined(separator: ", "))]"
            )
        }
    }

    private static func validateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "expected a non-symbolic-link directory at '\(url.path)'"
            )
        }
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
