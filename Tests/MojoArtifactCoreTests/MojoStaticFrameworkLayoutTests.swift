import Foundation
import MojoArtifactCore
import Testing

@Suite("Static framework layout")
struct MojoStaticFrameworkLayoutTests {
  @Test(.timeLimit(.minutes(1)))
  func createsVersionedMacOSFramework() throws {
    let fixture = try Fixture(style: .versioned)
    defer { fixture.remove() }

    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.frameworkURL
          .appendingPathComponent("Info.plist").path
      )
    )
    #expect(
      FileManager.default.fileExists(
        atPath: MojoStaticFrameworkLayout.informationPropertyListURL(
          in: fixture.frameworkURL,
          style: .versioned
        ).path
      )
    )
    #expect(try Data(contentsOf: fixture.binaryURL) == fixture.archive)
    #expect(
      try FileManager.default.destinationOfSymbolicLink(
        atPath: fixture.binaryURL.path
      ) == "Versions/Current/\(fixture.identity.moduleName)"
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func createsShallowIOSFramework() throws {
    let fixture = try Fixture(style: .shallow)
    defer { fixture.remove() }

    #expect(
      FileManager.default.fileExists(
        atPath: MojoStaticFrameworkLayout.informationPropertyListURL(
          in: fixture.frameworkURL,
          style: .shallow
        ).path
      )
    )
    #expect(
      !FileManager.default.fileExists(
        atPath: fixture.frameworkURL
          .appendingPathComponent("Versions").path
      )
    )
    #expect(try Data(contentsOf: fixture.binaryURL) == fixture.archive)
  }

  private struct Fixture {
    let rootURL: URL
    let frameworkURL: URL
    let identity: MojoArtifactIdentity
    let archive: Data

    var binaryURL: URL {
      frameworkURL.appendingPathComponent(identity.moduleName)
    }

    init(style: MojoStaticFrameworkLayout.Style) throws {
      rootURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      identity = try MojoArtifactIdentity(targetName: "LayoutFixture")
      frameworkURL = rootURL.appendingPathComponent(
        "\(identity.moduleName).framework",
        isDirectory: true
      )
      archive = Data("archive".utf8)
      try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: true
      )
      let archiveURL = rootURL.appendingPathComponent("input.a")
      try archive.write(to: archiveURL)
      try MojoStaticFrameworkLayout.createFramework(
        at: frameworkURL,
        identity: identity,
        archiveURL: archiveURL,
        header: "header",
        moduleMap: "module map",
        style: style
      )
    }

    func remove() {
      do {
        try FileManager.default.removeItem(at: rootURL)
      } catch {
        Issue.record("Failed to remove framework fixture: \(error)")
      }
    }
  }
}
