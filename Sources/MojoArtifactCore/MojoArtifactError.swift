import Foundation

package enum MojoArtifactError: Error, Equatable, CustomStringConvertible {
    case artifactArchiveCount(Int)
    case artifactDigestMismatch(expected: String, actual: String)
    case artifactIdentityMismatch(expected: String, actual: String)
    case artifactInterfaceMissing(String)
    case artifactMissing(String)
    case bindingGraphMismatch
    case commandFailed(command: String, status: Int32, diagnostic: String)
    case compilerDiagnostic(command: String, status: Int32, diagnostic: String)
    case compilerVersionMismatch(expected: String, actual: String)
    case configurationMissing(String)
    case externalPackageNotDeclared(String)
    case generationPipelineMismatch(expected: String, actual: String)
    case generatedSourceMismatch(expected: String, actual: String)
    case generatedSourceMissing(String)
    case invalidArguments(String)
    case invalidConfiguration(String)
    case invalidExternalPackage(String)
    case invalidManagedOutputDirectory(String)
    case invalidManifest(String)
    case inputGraphMismatch(expected: String, actual: String)
    case inputsChangedDuringOperation(String)
    case manifestMissing(String)
    case localPackageDependencyInRelease
    case packageManifestIntegrationMismatch(String)
    case outputLockFailed(path: String, diagnostic: String)
    case outputLockScopeMismatch(expected: String, actual: String)
    case outputPathsMustShareDirectory
    case sourceGraphMismatch(expected: String, actual: String)
    case sourceMapMismatch(expected: String, actual: String)
    case sourceMapMissing(String)
    case symbolicLinkUnsupported(String)
    case releaseRequiresCurrentManifest(Int)
    case releaseSliceMismatch(expected: String, actual: String)
    case sliceArchiveDigestMismatch(
        target: String,
        expected: String,
        actual: String
    )
    case sliceArchiveMissing(String)
    case sliceResolutionFailed(String)
    case targetSliceMissing(requested: String, prepared: String)
    case targetMismatch(
        expectedTriple: String,
        expectedCPU: String,
        actualTriple: String,
        actualCPU: String
    )
    case unmanagedOutputDirectory(String)
    case unsupportedTarget(String)
    case xcframeworkMetadataMismatch(String)

    package var description: String {
        switch self {
        case .artifactArchiveCount(let count):
            "The XCFramework archive count does not match its packaged libraries; found \(count) archive(s)"
        case .artifactDigestMismatch(let expected, let actual):
            "Prepared Mojo artifact digest is stale or corrupt; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .artifactIdentityMismatch(let expected, let actual):
            "Prepared Mojo module identity is '\(actual)', expected '\(expected)'. Run 'swift-mojo prepare'."
        case .artifactInterfaceMissing(let path):
            "Prepared Mojo XCFramework interface is missing '\(path)'. Run 'swift-mojo prepare'."
        case .artifactMissing(let path):
            "Prepared Mojo artifact is missing at '\(path)'. Run 'swift-mojo init' and then 'swift-mojo prepare'."
        case .bindingGraphMismatch:
            "Prepared Mojo binding records do not match the current Swift sources. Run 'swift-mojo prepare'."
        case .commandFailed(let command, let status, let diagnostic):
            "Command failed with status \(status): \(command)\(diagnostic.isEmpty ? "" : "\n\(diagnostic)")"
        case .compilerDiagnostic(let command, let status, let diagnostic):
            "Mojo compilation failed with status \(status): \(command)\(diagnostic.isEmpty ? "" : "\n\(diagnostic)")"
        case .compilerVersionMismatch(let expected, let actual):
            "Prepared Mojo compiler version is '\(actual)', expected pinned version '\(expected)'."
        case .configurationMissing(let path):
            "Release configuration is missing at '\(path)'"
        case .externalPackageNotDeclared(let package):
            "External Mojo package '\(package)' is referenced by @mojo but is not declared for the target"
        case .generationPipelineMismatch(let expected, let actual):
            "Prepared Mojo generation pipeline is stale; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .generatedSourceMismatch(let expected, let actual):
            "Generated Mojo source is stale or corrupt; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .generatedSourceMissing(let path):
            "Generated Mojo source is missing at '\(path)'. Run 'swift-mojo prepare'."
        case .invalidArguments(let message):
            message
        case .invalidConfiguration(let message):
            "SwiftMojo.json is invalid: \(message)"
        case .invalidExternalPackage(let message):
            "External Mojo package is invalid: \(message)"
        case .invalidManagedOutputDirectory(let path):
            "The managed output directory '\(path)' is incomplete. Move it aside and run 'swift-mojo init' again."
        case .invalidManifest(let message):
            "Mojo artifact manifest is invalid: \(message)"
        case .inputGraphMismatch(let expected, let actual):
            "Prepared Mojo input graph is stale; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .inputsChangedDuringOperation(let operation):
            "Swift Mojo inputs changed during \(operation); retry after source and configuration edits finish"
        case .manifestMissing(let path):
            "Prepared Mojo manifest is missing at '\(path)'. Run 'swift-mojo prepare'."
        case .localPackageDependencyInRelease:
            "Package.swift contains a local or non-literal package dependency and is not release-ready"
        case .packageManifestIntegrationMismatch(let detail):
            "Package.swift integration mismatch: \(detail)"
        case .outputLockFailed(let path, let diagnostic):
            "Failed to lock Mojo output at '\(path)': \(diagnostic)"
        case .outputLockScopeMismatch(let expected, let actual):
            "Mojo output lock for '\(expected)' cannot commit output at '\(actual)'"
        case .outputPathsMustShareDirectory:
            "The Mojo artifact and manifest must be managed in one generated output directory"
        case .sourceGraphMismatch(let expected, let actual):
            "Prepared Mojo sources are stale; manifest digest is \(expected), current digest is \(actual). Run 'swift-mojo prepare'."
        case .sourceMapMismatch(let expected, let actual):
            "Prepared Mojo source map is stale or corrupt; expected \(expected), found \(actual). Run 'swift-mojo prepare'."
        case .sourceMapMissing(let path):
            "Prepared Mojo source map is missing at '\(path)'. Run 'swift-mojo prepare'."
        case .symbolicLinkUnsupported(let path):
            "Release inputs and generated artifacts cannot be symbolic links: '\(path)'"
        case .releaseRequiresCurrentManifest(let version):
            "Release verification requires schema \(MojoArtifactManifest.currentSchemaVersion); found legacy schema \(version). Run 'swift-mojo prepare'."
        case .releaseSliceMismatch(let expected, let actual):
            "Prepared release slices do not match SwiftMojo.json; expected [\(expected)], found [\(actual)]."
        case .sliceArchiveDigestMismatch(let target, let expected, let actual):
            "Prepared Mojo archive for \(target) is stale or corrupt; expected \(expected), found \(actual)."
        case .sliceArchiveMissing(let target):
            "Prepared Mojo archive for slice '\(target)' is missing. Run 'swift-mojo prepare'."
        case .sliceResolutionFailed(let target):
            "The packaged XCFramework does not contain exactly one archive for slice '\(target)'"
        case .targetSliceMissing(let requested, let prepared):
            "Prepared Mojo artifact does not contain destination '\(requested)'; available slices: \(prepared)"
        case .targetMismatch(
            let expectedTriple,
            let expectedCPU,
            let actualTriple,
            let actualCPU
        ):
            "Prepared Mojo target \(expectedTriple)/\(expectedCPU) does not match the Swift destination \(actualTriple)/\(actualCPU). Run 'swift-mojo prepare' for the active destination."
        case .unmanagedOutputDirectory(let path):
            "Refusing to replace unmanaged output directory '\(path)'; choose an empty path or run 'swift-mojo init' first"
        case .unsupportedTarget(let target):
            "The XCFramework adapter supports Apple arm64/aarch64/x86_64 targets; received '\(target)'"
        case .xcframeworkMetadataMismatch(let message):
            "XCFramework metadata does not match the prepared slices: \(message)"
        }
    }
}
