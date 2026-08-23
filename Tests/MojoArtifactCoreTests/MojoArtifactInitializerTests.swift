import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Artifact initialization safety")
struct MojoArtifactInitializerTests {
  @Test(.timeLimit(.minutes(1)))
  func createsLinuxBootstrapForPackageResolution() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let identity = try MojoArtifactIdentity(targetName: "JetsonModel")
    let target = try MojoTargetConfiguration(
      triple: "aarch64-unknown-linux-gnu",
      cpu: "generic"
    )
    defer { removeArtifactFixture(root) }

    let initializer = MojoArtifactInitializer()
    let first = try initializer.initialize(
      outputDirectoryURL: root,
      identity: identity,
      targets: [target]
    )
    let second = try initializer.initialize(
      outputDirectoryURL: root,
      identity: identity,
      targets: [target]
    )

    #expect(first == .initialized)
    #expect(second == .alreadyInitialized)
    #expect(
      FileManager.default.fileExists(
        atPath: root.appendingPathComponent(
          identity.linuxArtifactName
        ).appendingPathComponent("info.json").path
      )
    )
  }

  @Test(.timeLimit(.minutes(1)))
  func preservesExistingPreparedArtifact() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let identity = try MojoArtifactIdentity(targetName: "PreparedModel")
    let target = try MojoTargetConfiguration(
      triple: "arm64-apple-macosx14.0",
      cpu: "generic"
    )
    let initializer = MojoArtifactInitializer()
    let first = try initializer.initialize(
      outputDirectoryURL: root,
      identity: identity,
      targets: [target]
    )
    let artifact = root.appendingPathComponent(
      identity.artifactName,
      isDirectory: true
    )
    let sentinel = artifact.appendingPathComponent("prepared-sentinel")
    try Data("prepared".utf8).write(to: sentinel)
    defer { removeArtifactFixture(root) }

    let disposition = try initializer.initialize(
      outputDirectoryURL: root,
      identity: identity,
      targets: [target]
    )

    #expect(first == .initialized)
    #expect(disposition == .alreadyInitialized)
    #expect(try Data(contentsOf: sentinel) == Data("prepared".utf8))
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsUnmanagedExistingDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    defer { removeArtifactFixture(root) }

    #expect(throws: MojoArtifactError.self) {
      _ = try MojoArtifactInitializer().initialize(
        outputDirectoryURL: root
      )
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func rejectsIncompleteManagedDirectory() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    try MojoOutputTransaction.markerContents.write(
      to: root.appendingPathComponent(MojoOutputTransaction.markerName)
    )
    defer { removeArtifactFixture(root) }

    #expect(throws: MojoArtifactError.self) {
      _ = try MojoArtifactInitializer().initialize(
        outputDirectoryURL: root
      )
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func symbolicLinkMarkerCannotClaimDirectoryOwnership() throws {
    let fileManager = FileManager.default
    let parent = fileManager.temporaryDirectory.appendingPathComponent(
      UUID().uuidString,
      isDirectory: true
    )
    let root = parent.appendingPathComponent("Generated", isDirectory: true)
    try fileManager.createDirectory(
      at: root,
      withIntermediateDirectories: true
    )
    let markerTarget = parent.appendingPathComponent("marker-target")
    try MojoOutputTransaction.markerContents.write(to: markerTarget)
    try fileManager.createSymbolicLink(
      at: root.appendingPathComponent(MojoOutputTransaction.markerName),
      withDestinationURL: markerTarget
    )
    defer { removeArtifactFixture(parent) }

    #expect(throws: MojoArtifactError.self) {
      _ = try MojoArtifactInitializer().initialize(
        outputDirectoryURL: root
      )
    }
  }
}

private func removeArtifactFixture(_ root: URL) {
  do {
    if FileManager.default.fileExists(atPath: root.path) {
      try FileManager.default.removeItem(at: root)
    }
  } catch {
    Issue.record("Failed to remove artifact fixture: \(error)")
  }
}
