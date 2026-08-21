import Foundation
import MojoBindingCore
import MojoCompilerCore

package enum MojoStaticLibraryArtifactBundleLayout {
    package struct Info: Codable, Equatable, Sendable {
        package struct Artifact: Codable, Equatable, Sendable {
            package struct Variant: Codable, Equatable, Sendable {
                package struct StaticLibraryMetadata: Codable, Equatable,
                    Sendable {
                    package let headerPaths: [String]
                    package let moduleMapPath: String
                }

                package let path: String
                package let supportedTriples: [String]
                package let staticLibraryMetadata: StaticLibraryMetadata
            }

            package let type: String
            package let version: String
            package let variants: [Variant]
        }

        package let schemaVersion: String
        package let artifacts: [String: Artifact]
    }

    package static let schemaVersion = "1.0"
    package static let artifactVersion = "1.0.0"
    package static let includeDirectory = "include"
    package static let moduleMapRelativePath = "include/module.modulemap"

    package static func create(
        at artifactURL: URL,
        identity: MojoArtifactIdentity,
        archives: [(target: MojoTargetConfiguration, archiveURL: URL)],
        header: String,
        moduleMap: String
    ) throws -> [MojoArtifactManifest.Slice] {
        guard !archives.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "A Linux static-library artifact requires at least one slice"
            )
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: artifactURL,
            withIntermediateDirectories: false
        )
        let includeURL = artifactURL.appendingPathComponent(
            includeDirectory,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: includeURL,
            withIntermediateDirectories: false
        )
        try header.write(
            to: includeURL.appendingPathComponent("\(identity.moduleName).h"),
            atomically: true,
            encoding: .utf8
        )
        try moduleMap.write(
            to: artifactURL.appendingPathComponent(moduleMapRelativePath),
            atomically: true,
            encoding: .utf8
        )

        var variants: [Info.Artifact.Variant] = []
        var slices: [MojoArtifactManifest.Slice] = []
        for archive in archives.sorted(by: {
            $0.target.identity < $1.target.identity
        }) {
            guard try MojoNativeArtifactAdapter(target: archive.target)
                    == .linuxStaticLibraryBundle else {
                throw MojoArtifactError.unsupportedTarget(
                    archive.target.triple
                )
            }
            let identifier = variantIdentifier(target: archive.target)
            let variantDirectory = artifactURL
                .appendingPathComponent("variants", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
            try fileManager.createDirectory(
                at: variantDirectory,
                withIntermediateDirectories: true
            )
            let destination = variantDirectory.appendingPathComponent(
                identity.libraryName
            )
            try fileManager.copyItem(
                at: archive.archiveURL,
                to: destination
            )
            variants.append(
                Info.Artifact.Variant(
                    path: "variants/\(identifier)/\(identity.libraryName)",
                    supportedTriples: [archive.target.triple],
                    staticLibraryMetadata: .init(
                        headerPaths: [includeDirectory],
                        moduleMapPath: moduleMapRelativePath
                    )
                )
            )
            slices.append(
                MojoArtifactManifest.Slice(
                    target: archive.target,
                    libraryIdentifier: identifier,
                    archiveDigest: try MojoCanonicalDigest.file(
                        at: destination
                    )
                )
            )
        }

        let info = Info(
            schemaVersion: schemaVersion,
            artifacts: [
                identity.linuxBinaryTargetName: Info.Artifact(
                    type: "staticLibrary",
                    version: artifactVersion,
                    variants: variants
                ),
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(
            to: artifactURL.appendingPathComponent("info.json"),
            options: .atomic
        )
        try validate(
            artifactURL: artifactURL,
            identity: identity,
            slices: slices
        )
        return slices
    }

    package static func validate(
        artifactURL: URL,
        identity: MojoArtifactIdentity,
        slices: [MojoArtifactManifest.Slice]
    ) throws {
        let infoURL = artifactURL.appendingPathComponent("info.json")
        let info: Info
        do {
            try MojoRegularFile.validate(at: infoURL)
            info = try JSONDecoder().decode(
                Info.self,
                from: Data(contentsOf: infoURL)
            )
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                String(describing: error)
            )
        }
        guard info.schemaVersion == schemaVersion,
              info.artifacts.count == 1,
              let artifact = info.artifacts[identity.linuxBinaryTargetName],
              artifact.type == "staticLibrary",
              artifact.version == artifactVersion,
              artifact.variants.count == slices.count else {
            throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                "unexpected schema, artifact identity, type, version, or variant count"
            )
        }
        var variantsByTriple: [String: Info.Artifact.Variant] = [:]
        for variant in artifact.variants {
            guard variant.supportedTriples.count == 1,
                  let triple = variant.supportedTriples.first,
                  variantsByTriple.updateValue(variant, forKey: triple)
                    == nil else {
                throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                    "every variant must name one unique supported triple"
                )
            }
        }
        for slice in slices {
            guard let variant = variantsByTriple[slice.target.triple],
                  variant.path
                    == "variants/\(slice.libraryIdentifier)/\(identity.libraryName)",
                  variant.staticLibraryMetadata.headerPaths
                    == [includeDirectory],
                  variant.staticLibraryMetadata.moduleMapPath
                    == moduleMapRelativePath else {
                throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                    "variant metadata does not match slice '\(slice.target.identity)'"
                )
            }
            let archiveURL = artifactURL.appendingPathComponent(variant.path)
            try MojoRegularFile.validate(at: archiveURL)
            let digest = try MojoCanonicalDigest.file(at: archiveURL)
            guard digest == slice.archiveDigest else {
                throw MojoArtifactError.sliceArchiveDigestMismatch(
                    target: slice.target.identity,
                    expected: slice.archiveDigest,
                    actual: digest
                )
            }
        }
        for required in [
            artifactURL.appendingPathComponent(
                "\(includeDirectory)/\(identity.moduleName).h"
            ),
            artifactURL.appendingPathComponent(moduleMapRelativePath),
        ] {
            try MojoRegularFile.validate(at: required)
        }
    }

    package static func resolveSlices(
        artifactURL: URL,
        identity: MojoArtifactIdentity,
        targets: [MojoTargetConfiguration]
    ) throws -> [MojoArtifactManifest.Slice] {
        let infoURL = artifactURL.appendingPathComponent("info.json")
        let info: Info
        do {
            try MojoRegularFile.validate(at: infoURL)
            info = try JSONDecoder().decode(
                Info.self,
                from: Data(contentsOf: infoURL)
            )
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                String(describing: error)
            )
        }
        guard info.schemaVersion == schemaVersion,
              info.artifacts.count == 1,
              let artifact = info.artifacts[identity.linuxBinaryTargetName],
              artifact.type == "staticLibrary",
              artifact.version == artifactVersion else {
            throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                "unexpected schema, artifact identity, type, or version"
            )
        }
        var slices: [MojoArtifactManifest.Slice] = []
        for target in targets {
            let matches = artifact.variants.filter {
                $0.supportedTriples == [target.triple]
            }
            guard matches.count == 1, let variant = matches.first else {
                throw MojoArtifactError.sliceResolutionFailed(target.identity)
            }
            let identifier = variantIdentifier(target: target)
            guard variant.path
                    == "variants/\(identifier)/\(identity.libraryName)" else {
                throw MojoArtifactError.staticLibraryBundleMetadataMismatch(
                    "variant path does not match target '\(target.identity)'"
                )
            }
            let archiveURL = artifactURL.appendingPathComponent(variant.path)
            try MojoRegularFile.validate(at: archiveURL)
            slices.append(
                MojoArtifactManifest.Slice(
                    target: target,
                    libraryIdentifier: identifier,
                    archiveDigest: try MojoCanonicalDigest.file(at: archiveURL)
                )
            )
        }
        let result = slices.sorted { $0.target.identity < $1.target.identity }
        try validate(
            artifactURL: artifactURL,
            identity: identity,
            slices: result
        )
        return result
    }

    package static func archiveURL(
        in artifactURL: URL,
        identity: MojoArtifactIdentity,
        slice: MojoArtifactManifest.Slice
    ) -> URL {
        artifactURL
            .appendingPathComponent("variants", isDirectory: true)
            .appendingPathComponent(
                slice.libraryIdentifier,
                isDirectory: true
            )
            .appendingPathComponent(identity.libraryName)
    }

    private static func variantIdentifier(
        target: MojoTargetConfiguration
    ) -> String {
        "linux-\(MojoCanonicalDigest.hex(target.identity))"
    }
}
