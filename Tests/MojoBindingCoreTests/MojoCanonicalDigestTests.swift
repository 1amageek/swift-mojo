import Foundation
import MojoBindingCore
import Testing

@Suite("Canonical tree digest symbolic links")
struct MojoCanonicalDigestTests {
  @Test(.timeLimit(.minutes(1)))
  func preservesCanonicalSHA256GoldenValues() {
    #expect(
      MojoCanonicalDigest.hex("")
        == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    )
    #expect(
      MojoCanonicalDigest.hex(Data("canonical-data".utf8))
        == "a8d75b82f52bfda0e6c0bf62e2a4233575225c69b249a2b5dd37b2939fc8d452"
    )
    #expect(MojoCanonicalDigest.identifier("swift-mojo") == 7_576_566_814_227_521_019)
  }

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

    #expect(
      digest
        == "472ddb216015f97e4690c46d09cb6db08b3688e1ad4467702f0f4162d5c9ff90"
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func includesRegularFilesThatSortAfterASymbolicLink() throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let link = fixture.root.appendingPathComponent("Binary")
    try FileManager.default.createSymbolicLink(
      atPath: link.path,
      withDestinationPath: "A/payload"
    )
    let contract = ["Binary": "A/payload"]
    let original = try MojoCanonicalDigest.tree(
      at: fixture.root,
      allowedSymbolicLinks: contract
    )

    try Data("changed".utf8).write(
      to: fixture.root.appendingPathComponent("A/payload")
    )

    let changed = try MojoCanonicalDigest.tree(
      at: fixture.root,
      allowedSymbolicLinks: contract
    )
    #expect(changed != original)
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
