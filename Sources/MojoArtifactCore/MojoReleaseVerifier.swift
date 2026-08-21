import Foundation
import MojoBindingCore

package struct MojoReleaseVerifier: Sendable {
    private let artifactVerifier: MojoArtifactVerifier
    private let transaction: MojoOutputTransaction

    package init(
        artifactVerifier: MojoArtifactVerifier = MojoArtifactVerifier(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.artifactVerifier = artifactVerifier
        self.transaction = transaction
    }

    package func verify(
        layout: MojoPackageLayout,
        sourceURLs: [URL]
    ) throws -> MojoReleaseReport {
        try transaction.withExclusiveAccess(
            to: layout.outputDirectoryURL
        ) { _ in
            try verifyWhileOutputIsLocked(
                layout: layout,
                sourceURLs: sourceURLs
            )
        }
    }

    private func verifyWhileOutputIsLocked(
        layout: MojoPackageLayout,
        sourceURLs: [URL]
    ) throws -> MojoReleaseReport {
        let configurationURL = layout.packageRootURL.appendingPathComponent(
            SwiftMojoConfiguration.fileName
        )
        guard FileManager.default.fileExists(atPath: configurationURL.path) else {
            throw MojoArtifactError.configurationMissing(configurationURL.path)
        }
        try MojoRegularFile.validate(at: configurationURL)
        let configurationData: Data
        do {
            configurationData = try Data(contentsOf: configurationURL)
        } catch {
            throw MojoArtifactError.invalidConfiguration(
                "Cannot read '\(configurationURL.path)': \(error)"
            )
        }
        let configuration = try SwiftMojoConfiguration.decode(
            configurationData
        )
        let configurationDigest = MojoCanonicalDigest.hex(configurationData)
        let targetConfiguration = try configuration.target(
            named: layout.targetName
        )
        let binaryIntegrations = try layout.binaryIntegrations(
            targets: targetConfiguration.slices
        )
        let packageManifestDigest = try PackageManifestReleaseInspector
            .validateReleaseIntegration(
                packageRootURL: layout.packageRootURL,
                targetName: layout.targetName,
                binaryIntegrations: binaryIntegrations
            )
        let externalPackages = try layout.externalPackages(
            names: targetConfiguration.mojoPackages
        )
        let options = try MojoVerifyOptions(
            sourceURLs: sourceURLs,
            sourceRootURL: layout.packageRootURL,
            externalPackages: externalPackages,
            outputDirectoryURL: layout.outputDirectoryURL,
            generatedSourceURL: layout.outputDirectoryURL
                .appendingPathComponent(".release-validation-unused.swift"),
            expectedIdentity: layout.identity,
            expectedCompilerVersion: targetConfiguration.compilerVersion,
            expectedSlices: targetConfiguration.slices
        )
        let validation = try artifactVerifier.validateAssumingOutputLock(
            options: options
        )
        let manifest = validation.manifest
        guard manifest.schemaVersion
                == MojoArtifactManifest.currentSchemaVersion else {
            throw MojoArtifactError.releaseRequiresCurrentManifest(
                manifest.schemaVersion
            )
        }
        guard manifest.artifactIdentity == layout.identity else {
            throw MojoArtifactError.artifactIdentityMismatch(
                expected: layout.identity.moduleName,
                actual: manifest.effectiveIdentity.moduleName
            )
        }
        guard manifest.compilerVersion == targetConfiguration.compilerVersion else {
            throw MojoArtifactError.compilerVersionMismatch(
                expected: targetConfiguration.compilerVersion,
                actual: manifest.compilerVersion
            )
        }
        let expectedSlices = targetConfiguration.slices.sorted {
            $0.identity < $1.identity
        }
        let actualSlices = manifest.effectiveSlices.map(\.target).sorted {
            $0.identity < $1.identity
        }
        guard actualSlices == expectedSlices else {
            throw MojoArtifactError.releaseSliceMismatch(
                expected: expectedSlices.map(\.identity).joined(separator: ", "),
                actual: actualSlices.map(\.identity).joined(separator: ", ")
            )
        }
        let expectedPackages = externalPackages.map(\.manifestRecord)
        guard manifest.externalPackages == expectedPackages else {
            throw MojoArtifactError.inputGraphMismatch(
                expected: String(describing: manifest.externalPackages ?? []),
                actual: String(describing: expectedPackages)
            )
        }
        let finalInputGraph = try options.inputGraph()
        let finalConfigurationDigest: String
        let finalPackageManifestDigest: String
        do {
            finalConfigurationDigest = try MojoCanonicalDigest.file(
                at: configurationURL
            )
            finalPackageManifestDigest = try MojoCanonicalDigest.file(
                at: layout.packageRootURL.appendingPathComponent(
                    "Package.swift"
                )
            )
        } catch {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "release verification"
            )
        }
        guard finalInputGraph == validation.inputGraph,
              finalConfigurationDigest == configurationDigest,
              finalPackageManifestDigest == packageManifestDigest else {
            throw MojoArtifactError.inputsChangedDuringOperation(
                "release verification"
            )
        }
        return MojoReleaseReport(
            targetName: layout.targetName,
            manifest: manifest
        )
    }
}
