import Foundation
import MojoBindingCore
import Testing

@Suite("Canonical tree digest symbolic links")
struct MojoCanonicalDigestTests {
  @Test(.timeLimit(.minutes(1)))
  func hashesAnExplicitInternalSymbolicLinkContract() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root.appendingPathComponent("Current").path,
      withDestinationPath: "A"
    )

    let digest = try MojoCanonicalDigest.tree(
      at: fixture.root,
      allowedSymbolicLinks: ["Current": "A"]
    )

    #expect(!digest.isEmpty)
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsAnUnlistedSymbolicLink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let link = fixture.root.appendingPathComponent("Current")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "A"
    )

    #expect(
      throws: MojoCanonicalDigestError.symbolicLink(link.path)
    ) {
      _ = try MojoCanonicalDigest.tree(at: fixture.root)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsAnAllowedLinkThatEscapesTheTree() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let link = fixture.root.appendingPathComponent("Escape")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "../outside"
    )

    #expect(
      throws: MojoCanonicalDigestError.symbolicLinkEscapesRoot(link.path)
    ) {
      _ = try MojoCanonicalDigest.tree(
        at: fixture.root,
        allowedSymbolicLinks: ["Escape": "../outside"]
      )
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsAMissingRequiredLink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }

    #expect(
      throws: MojoCanonicalDigestError.symbolicLinkMissing("Current")
    ) {
      _ = try MojoCanonicalDigest.tree(
        at: fixture.root,
        allowedSymbolicLinks: ["Current": "A"]
      )
    }
  }

  private struct Fixture {
    let root: URL

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
      let version = root.appendingPathComponent("A", isDirectory: true)
      try FileManager.default.createDirectory(
        at: version,
        withIntermediateDirectories: true
      )
      try Data("payload".utf8).write(
        to: version.appendingPathComponent("payload")
      )
    }

    func remove() {
      do {
        try FileManager.default.removeItem(at: root)
      } catch {
        Issue.record("Failed to remove digest fixture: \(error)")
      }
    }
  }
}
