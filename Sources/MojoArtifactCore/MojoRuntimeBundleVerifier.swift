import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeBundleVerifier: Sendable {
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
    ) throws -> MojoRuntimeBundleManifest {
        let root = bundleURL.standardizedFileURL
        guard transaction.isManaged(root) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "bundle is not a managed swift-mojo output at '\(root.path)'"
            )
        }
        try Self.validateDirectory(root)
        let manifestURL = root.appendingPathComponent(
            MojoRuntimeBundleManifest.fileName
        )
        let receiptURL = root.appendingPathComponent(
            MojoRuntimeBundleManifest.receiptFileName
        )
        try MojoRegularFile.validate(at: manifestURL)
        try MojoRegularFile.validate(at: receiptURL)
        let manifest = try MojoRuntimeBundleManifest.decode(
            Data(contentsOf: manifestURL)
        )
        let receipt = try MojoRuntimeDependencyReceipt.decode(
            Data(contentsOf: receiptURL)
        )
        guard manifest.receiptDigest == receipt.digest,
              manifest.target == receipt.target else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "manifest and runtime receipt identities do not match"
            )
        }
        let executableRelativePath = "bin/" + root
            .appendingPathComponent(manifest.executable.relativePath)
            .lastPathComponent
        guard manifest.executable.relativePath == executableRelativePath else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable path must be a direct child of bin"
            )
        }
        let expectedLibraries = receipt.libraries.map {
            MojoRuntimeBundleManifest.File(
                relativePath: "lib/\($0.fileName)",
                digest: $0.digest
            )
        }
        guard manifest.libraries == expectedLibraries else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "manifest library files do not match the runtime receipt"
            )
        }
        try validateLayout(
            root: root,
            executableName: manifest.executable.relativePath
                .split(separator: "/").last.map(String.init) ?? "",
            libraryNames: receipt.libraries.map(\.fileName)
        )
        let executableURL = root.appendingPathComponent(
            manifest.executable.relativePath
        )
        let libraryURLs = receipt.libraries.map {
            root.appendingPathComponent("lib/\($0.fileName)")
        }
        try MojoRegularFile.validate(at: executableURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path)
        else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "runtime executable is not executable at '\(executableURL.path)'"
            )
        }
        guard try MojoCanonicalDigest.file(at: executableURL)
                == manifest.executable.digest else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "executable digest does not match the manifest"
            )
        }
        for (record, url) in zip(manifest.libraries, libraryURLs) {
            try MojoRegularFile.validate(at: url)
            guard try MojoCanonicalDigest.file(at: url) == record.digest else {
                throw MojoArtifactError.invalidRuntimeBundle(
                    "runtime library digest does not match for '\(url.lastPathComponent)'"
                )
            }
        }
        let inspection = try validateContents(
            receipt: receipt,
            executableURL: executableURL,
            libraryURLs: libraryURLs
        )
        let expectedLoaderSearchPath = try MojoRuntimeLoaderPolicy
            .expectedSearchPath(target: receipt.target)
        guard manifest.loaderSearchPath == expectedLoaderSearchPath,
              manifest.programInterpreter == inspection.programInterpreter,
              manifest.systemDependencies
                == Self.systemDependencies(
                    inspection: inspection,
                    receipt: receipt
                ) else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "manifest loader metadata does not match the executable"
            )
        }
        return manifest
    }

    package func validateContents(
        receipt: MojoRuntimeDependencyReceipt,
        executableURL: URL,
        libraryURLs: [URL]
    ) throws -> MojoRuntimeExecutableInspection {
        try MojoRuntimeLoaderPolicy.validate(receipt: receipt)
        let allowedSystemDependencies: Set<String>
        if receipt.target.triple.lowercased().contains("-linux-") {
            allowedSystemDependencies = Set(receipt.systemDependencies)
        } else {
            allowedSystemDependencies = []
        }
        let current = try receiptPreparer.prepare(
            options: MojoRuntimeReceiptOptions(
                objectURL: executableURL,
                libraryURLs: libraryURLs,
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
                "linked executable does not reproduce the receipt runtime closure"
            )
        }
        let inspection = try binaryInspector.inspectExecutable(
            executableURL: executableURL,
            target: receipt.target
        )
        try MojoRuntimeLoaderPolicy.validate(
            executable: inspection,
            receipt: receipt
        )
        return inspection
    }

    package static func systemDependencies(
        inspection: MojoRuntimeExecutableInspection,
        receipt: MojoRuntimeDependencyReceipt
    ) -> [String] {
        let runtime = Set(receipt.libraries.map(\.installName))
        return inspection.dynamicDependencies.filter {
            !runtime.contains($0)
        }.sorted()
    }

    private func validateLayout(
        root: URL,
        executableName: String,
        libraryNames: [String]
    ) throws {
        let expectedRoot = Set([
            MojoOutputTransaction.markerName,
            MojoRuntimeBundleManifest.fileName,
            MojoRuntimeBundleManifest.receiptFileName,
            "bin",
            "lib",
        ])
        try Self.validateEntries(directory: root, expected: expectedRoot)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try Self.validateDirectory(bin)
        try Self.validateDirectory(lib)
        try Self.validateEntries(directory: bin, expected: [executableName])
        try Self.validateEntries(
            directory: lib,
            expected: Set(libraryNames)
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
                "directory '\(directory.path)' contains "
                    + "[\(actual.sorted().joined(separator: ", "))], expected "
                    + "[\(expected.sorted().joined(separator: ", "))]"
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
}
