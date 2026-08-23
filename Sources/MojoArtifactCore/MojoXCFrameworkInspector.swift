import Foundation
import MojoBindingCore
import MojoCompilerCore

package enum MojoXCFrameworkInspector {
  private struct Information: Decodable {
    let availableLibraries: [Library]

    private enum CodingKeys: String, CodingKey {
      case availableLibraries = "AvailableLibraries"
    }
  }

  private struct Library: Decodable {
    let libraryIdentifier: String
    let libraryPath: String
    let binaryPath: String?
    let headersPath: String?
    let supportedArchitectures: [String]
    let supportedPlatform: String
    let supportedPlatformVariant: String?

    private enum CodingKeys: String, CodingKey {
      case libraryIdentifier = "LibraryIdentifier"
      case libraryPath = "LibraryPath"
      case binaryPath = "BinaryPath"
      case headersPath = "HeadersPath"
      case supportedArchitectures = "SupportedArchitectures"
      case supportedPlatform = "SupportedPlatform"
      case supportedPlatformVariant = "SupportedPlatformVariant"
    }
  }

  package static func validate(
    artifactURL: URL,
    identity: MojoArtifactIdentity,
    slices: [MojoArtifactManifest.Slice]
  ) throws {
    let information = try information(at: artifactURL)
    try validateLibrarySet(
      information.availableLibraries,
      expectedCount: Set(slices.map(\.libraryIdentifier)).count
    )
    for library in information.availableLibraries {
      let matchingSlices = slices.filter {
        $0.libraryIdentifier == library.libraryIdentifier
      }
      guard !matchingSlices.isEmpty else {
        throw MojoArtifactError.xcframeworkMetadataMismatch(
          "Unexpected library identifier '\(library.libraryIdentifier)'"
        )
      }
      let expected = try matchingSlices.map {
        try MojoXCFrameworkSliceIdentity(target: $0.target)
      }
      let expectedArchitectures = Set(expected.map(\.architecture))
      guard let first = expected.first else {
        throw MojoArtifactError.xcframeworkMetadataMismatch(
          "Library '\(library.libraryIdentifier)' has no manifest targets"
        )
      }
      let frameworkName = MojoStaticFrameworkLayout.frameworkName(
        identity: identity
      )
      let style = MojoStaticFrameworkLayout.style(
        forApplePlatform: first.platform
      )
      guard library.libraryPath == frameworkName,
        library.binaryPath
          == MojoStaticFrameworkLayout.binaryPath(
            identity: identity,
            style: style
          ),
        library.headersPath == nil,
        Set(library.supportedArchitectures)
          == expectedArchitectures,
        expected.allSatisfy({
          $0.platform == first.platform
            && $0.variant == first.variant
        }),
        library.supportedPlatform == first.platform,
        library.supportedPlatformVariant == first.variant
      else {
        throw MojoArtifactError.xcframeworkMetadataMismatch(
          "Library '\(library.libraryIdentifier)' does not match its manifest targets"
        )
      }
    }
  }

  package static func resolveSlices(
    artifactURL: URL,
    identity: MojoArtifactIdentity,
    targets: [MojoTargetConfiguration]
  ) throws -> [MojoArtifactManifest.Slice] {
    let libraries = try information(at: artifactURL).availableLibraries
    let selectors = try targets.map(MojoXCFrameworkSliceIdentity.init)
    try validateLibrarySet(
      libraries,
      expectedCount: Set(selectors.map(\.libraryGroupIdentity)).count
    )
    var slices: [MojoArtifactManifest.Slice] = []
    for target in targets {
      let expected = try MojoXCFrameworkSliceIdentity(target: target)
      let frameworkName = MojoStaticFrameworkLayout.frameworkName(
        identity: identity
      )
      let style = MojoStaticFrameworkLayout.style(
        forApplePlatform: expected.platform
      )
      let matches = libraries.filter { library in
        return library.libraryPath == frameworkName
          && library.binaryPath
            == MojoStaticFrameworkLayout.binaryPath(
              identity: identity,
              style: style
            )
          && library.headersPath == nil
          && library.supportedArchitectures.contains(
            expected.architecture
          )
          && library.supportedPlatform == expected.platform
          && library.supportedPlatformVariant == expected.variant
      }
      guard matches.count == 1, let match = matches.first else {
        throw MojoArtifactError.sliceResolutionFailed(
          target.identity
        )
      }
      let library = match
      let sliceURL =
        artifactURL
        .appendingPathComponent(
          library.libraryIdentifier,
          isDirectory: true
        )
      let archiveURL = MojoStaticFrameworkLayout.binaryURL(
        in: sliceURL,
        identity: identity
      )
      guard FileManager.default.fileExists(atPath: archiveURL.path) else {
        throw MojoArtifactError.sliceArchiveMissing(target.identity)
      }
      slices.append(
        MojoArtifactManifest.Slice(
          target: target,
          libraryIdentifier: library.libraryIdentifier,
          archiveDigest: try MojoCanonicalDigest.file(at: archiveURL)
        )
      )
    }
    guard Set(slices.map(\.libraryIdentifier)).count == libraries.count else {
      throw MojoArtifactError.artifactArchiveCount(libraries.count)
    }
    let result = slices.sorted { $0.target.identity < $1.target.identity }
    try validate(
      artifactURL: artifactURL,
      identity: identity,
      slices: result
    )
    return result
  }

  private static func information(
    at artifactURL: URL
  ) throws -> Information {
    let plistURL = artifactURL.appendingPathComponent("Info.plist")
    do {
      return try PropertyListDecoder().decode(
        Information.self,
        from: Data(contentsOf: plistURL)
      )
    } catch {
      throw MojoArtifactError.xcframeworkMetadataMismatch(
        "Info.plist cannot be decoded: \(error)"
      )
    }
  }

  private static func validateLibrarySet(
    _ libraries: [Library],
    expectedCount: Int
  ) throws {
    guard libraries.count == expectedCount else {
      throw MojoArtifactError.xcframeworkMetadataMismatch(
        "Info.plist declares \(libraries.count) libraries for \(expectedCount) manifest slices"
      )
    }
    guard
      Set(libraries.map(\.libraryIdentifier)).count
        == libraries.count
    else {
      throw MojoArtifactError.xcframeworkMetadataMismatch(
        "Info.plist contains duplicate library identifiers"
      )
    }
  }

}
