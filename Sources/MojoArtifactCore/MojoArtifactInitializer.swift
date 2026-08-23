import Foundation
import MojoCompilerCore

package struct MojoArtifactInitializer: Sendable {
  private let processRunner: any MojoProcessRunning
  private let renderer: MojoStaticSourceRenderer
  private let transaction: MojoOutputTransaction

  package init(
    processRunner: any MojoProcessRunning = FoundationMojoProcessRunner(),
    renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
    transaction: MojoOutputTransaction = MojoOutputTransaction()
  ) {
    self.processRunner = processRunner
    self.renderer = renderer
    self.transaction = transaction
  }

  @discardableResult
  package func initialize(
    outputDirectoryURL: URL,
    identity: MojoArtifactIdentity = .legacy,
    targets: [MojoTargetConfiguration]? = nil
  ) throws -> MojoInitializationDisposition {
    let resolvedTargets: [MojoTargetConfiguration]
    if let targets {
      resolvedTargets = targets
    } else {
      resolvedTargets = [try Self.hostTarget()]
    }
    guard !resolvedTargets.isEmpty else {
      throw MojoArtifactError.invalidArguments(
        "Artifact initialization requires at least one target"
      )
    }
    try MojoNativeArtifactAdapter.validate(
      targets: resolvedTargets,
      error: MojoArtifactError.invalidArguments
    )
    return try transaction.withExclusiveAccess(
      to: outputDirectoryURL
    ) { access in
      try initialize(
        outputDirectoryURL: outputDirectoryURL,
        identity: identity,
        targets: resolvedTargets,
        access: access
      )
    }
  }

  private func initialize(
    outputDirectoryURL: URL,
    identity: MojoArtifactIdentity,
    targets: [MojoTargetConfiguration],
    access: MojoOutputTransaction.ExclusiveAccess
  ) throws -> MojoInitializationDisposition {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: outputDirectoryURL.path) {
      guard transaction.isManaged(outputDirectoryURL) else {
        throw MojoArtifactError.unmanagedOutputDirectory(
          outputDirectoryURL.path
        )
      }
      try validateExistingArtifacts(
        in: outputDirectoryURL,
        identity: identity,
        targets: targets
      )
      return .alreadyInitialized
    }
    let staging = try transaction.makeStagingDirectory(
      for: outputDirectoryURL
    )
    do {
      try createBootstrap(
        in: staging,
        identity: identity,
        targets: targets
      )
      try transaction.commit(
        stagingURL: staging,
        outputURL: outputDirectoryURL,
        access: access
      )
    } catch {
      do {
        if FileManager.default.fileExists(atPath: staging.path) {
          try FileManager.default.removeItem(at: staging)
        }
      } catch let cleanupError {
        throw MojoArtifactError.commandFailed(
          command: "clean bootstrap staging directory",
          status: -1,
          diagnostic: "Primary error: \(error); cleanup error: \(cleanupError)"
        )
      }
      throw error
    }
    return .initialized
  }

  private func createBootstrap(
    in staging: URL,
    identity: MojoArtifactIdentity,
    targets: [MojoTargetConfiguration]
  ) throws {
    let buildURL = staging.appendingPathComponent(
      ".bootstrap",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: buildURL,
      withIntermediateDirectories: false
    )
    let sourceURL = buildURL.appendingPathComponent("Bootstrap.c")
    let prefix = identity.symbolPrefix
    let graphFunction =
      identity == .legacy
      ? "\(prefix)_source_graph_identifier"
      : "\(prefix)_input_graph_identifier"
    // FIXME(INCOMPLETE_IMPLEMENTATION): The init command emits an
    // intentionally invalid bootstrap ABI so SwiftPM can load the local
    // binary-target path. Normal build verification rejects this path
    // because it has no manifest. It must never be treated as prepared
    // until prepare replaces it with a compiler-produced artifact and
    // matching manifest.
    let source = """
      typedef unsigned int uint32_t;
      typedef unsigned long long uint64_t;
      typedef int int32_t;

      uint32_t \(prefix)_static_abi_version(void) { return 0; }
      uint64_t \(graphFunction)(void) { return 0; }
      uint32_t \(prefix)_has_binding(uint64_t binding_id) {
          (void)binding_id;
          return 0;
      }
      int32_t \(prefix)_call_i32_i32_i32(
          uint64_t binding_id,
          int32_t lhs,
          int32_t rhs
      ) {
          (void)binding_id;
          (void)lhs;
          (void)rhs;
          __builtin_trap();
      }
      """ + "\n"
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    let header =
      identity == .legacy
      ? renderer.header
      : renderer.header(identity: identity)
    let groups = try Dictionary(grouping: targets) {
      try MojoNativeArtifactAdapter(target: $0)
    }
    if groups[.appleXCFramework] != nil {
      try createAppleBootstrap(
        sourceURL: sourceURL,
        buildURL: buildURL,
        stagingURL: staging,
        identity: identity,
        header: header
      )
    }
    if let linuxTargets = groups[.linuxStaticLibraryBundle] {
      try createLinuxBootstrap(
        sourceURL: sourceURL,
        buildURL: buildURL,
        stagingURL: staging,
        identity: identity,
        header: header,
        targets: linuxTargets
      )
    }
    try FileManager.default.removeItem(at: buildURL)
  }

  private func createAppleBootstrap(
    sourceURL: URL,
    buildURL: URL,
    stagingURL: URL,
    identity: MojoArtifactIdentity,
    header: String
  ) throws {
    let objectURL = buildURL.appendingPathComponent("AppleBootstrap.o")
    let archiveURL = buildURL.appendingPathComponent(identity.libraryName)
    let frameworkURL = MojoStaticFrameworkLayout.frameworkURL(
      in: buildURL,
      identity: identity
    )
    let artifactURL = stagingURL.appendingPathComponent(
      identity.artifactName,
      isDirectory: true
    )
    try run(
      executablePath: "/usr/bin/xcrun",
      arguments: [
        "clang",
        "-arch", Self.hostArchitecture,
        "-mmacosx-version-min=14.0",
        "-c", sourceURL.path,
        "-o", objectURL.path,
      ]
    )
    try run(
      executablePath: "/usr/bin/ar",
      arguments: ["rcs", archiveURL.path, objectURL.path]
    )
    try MojoStaticFrameworkLayout.createFramework(
      at: frameworkURL,
      identity: identity,
      archiveURL: archiveURL,
      header: header,
      moduleMap: renderer.frameworkModuleMap(identity: identity),
      style: .versioned
    )
    try run(
      executablePath: "/usr/bin/xcrun",
      arguments: [
        "xcodebuild",
        "-create-xcframework",
        "-framework", frameworkURL.path,
        "-output", artifactURL.path,
      ]
    )
  }

  private func createLinuxBootstrap(
    sourceURL: URL,
    buildURL: URL,
    stagingURL: URL,
    identity: MojoArtifactIdentity,
    header: String,
    targets: [MojoTargetConfiguration]
  ) throws {
    var archives:
      [(
        target: MojoTargetConfiguration,
        archiveURL: URL
      )] = []
    for (index, target) in targets.sorted(by: {
      $0.identity < $1.identity
    }).enumerated() {
      let directory = buildURL.appendingPathComponent(
        "linux-\(index)",
        isDirectory: true
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false
      )
      let objectURL = directory.appendingPathComponent("Bootstrap.o")
      let archiveURL = directory.appendingPathComponent(
        identity.libraryName
      )
      try run(
        executablePath: "/usr/bin/xcrun",
        arguments: [
          "clang",
          "-target", target.triple,
          "-ffreestanding",
          "-c", sourceURL.path,
          "-o", objectURL.path,
        ]
      )
      try run(
        executablePath: "/usr/bin/ar",
        arguments: ["rcs", archiveURL.path, objectURL.path]
      )
      archives.append((target: target, archiveURL: archiveURL))
    }
    _ = try MojoStaticLibraryArtifactBundleLayout.create(
      at: stagingURL.appendingPathComponent(
        identity.linuxArtifactName,
        isDirectory: true
      ),
      identity: identity,
      archives: archives,
      header: header,
      moduleMap: renderer.moduleMap(identity: identity)
    )
  }

  private func validateExistingArtifacts(
    in outputDirectoryURL: URL,
    identity: MojoArtifactIdentity,
    targets: [MojoTargetConfiguration]
  ) throws {
    let fileManager = FileManager.default
    let groups = try Dictionary(grouping: targets) {
      try MojoNativeArtifactAdapter(target: $0)
    }
    if groups[.appleXCFramework] != nil {
      let artifactURL = outputDirectoryURL.appendingPathComponent(
        identity.artifactName,
        isDirectory: true
      )
      guard fileManager.fileExists(atPath: artifactURL.path) else {
        throw MojoArtifactError.invalidManagedOutputDirectory(
          outputDirectoryURL.path
        )
      }
      let infoPlistURL = artifactURL.appendingPathComponent("Info.plist")
      guard fileManager.fileExists(atPath: infoPlistURL.path) else {
        throw MojoArtifactError.invalidManagedOutputDirectory(
          outputDirectoryURL.path
        )
      }
      let slices = try MojoXCFrameworkInspector.resolveSlices(
        artifactURL: artifactURL,
        identity: identity,
        targets: groups[.appleXCFramework, default: []]
      )
      for slice in slices {
        let frameworkURL = MojoStaticFrameworkLayout.frameworkURL(
          in: artifactURL.appendingPathComponent(
            slice.libraryIdentifier,
            isDirectory: true
          ),
          identity: identity
        )
        let selector = try MojoXCFrameworkSliceIdentity(
          target: slice.target
        )
        let style = MojoStaticFrameworkLayout.style(
          forApplePlatform: selector.platform
        )
        do {
          try MojoStaticFrameworkLayout.validateFramework(
            at: frameworkURL,
            identity: identity,
            style: style
          )
        } catch {
          throw MojoArtifactError.invalidManagedOutputDirectory(
            outputDirectoryURL.path
          )
        }
      }
    }
    if let linuxTargets = groups[.linuxStaticLibraryBundle] {
      let artifactURL = outputDirectoryURL.appendingPathComponent(
        identity.linuxArtifactName,
        isDirectory: true
      )
      guard fileManager.fileExists(atPath: artifactURL.path) else {
        throw MojoArtifactError.invalidManagedOutputDirectory(
          outputDirectoryURL.path
        )
      }
      do {
        _ = try MojoStaticLibraryArtifactBundleLayout.resolveSlices(
          artifactURL: artifactURL,
          identity: identity,
          targets: linuxTargets
        )
      } catch {
        throw MojoArtifactError.invalidManagedOutputDirectory(
          outputDirectoryURL.path
        )
      }
    }
  }

  private static var hostArchitecture: String {
    #if arch(arm64)
      "arm64"
    #elseif arch(x86_64)
      "x86_64"
    #else
      "unsupported-host"
    #endif
  }

  private static func hostTarget() throws -> MojoTargetConfiguration {
    try MojoTargetConfiguration(
      triple: "\(hostArchitecture)-apple-macosx14.0",
      cpu: "generic"
    )
  }

  private func run(
    executablePath: String,
    arguments: [String]
  ) throws {
    let result = try processRunner.capture(
      executablePath: executablePath,
      arguments: arguments
    )
    guard result.status == 0 else {
      throw MojoArtifactError.commandFailed(
        command: ([executablePath] + arguments).joined(separator: " "),
        status: result.status,
        diagnostic: result.output
          .trimmingCharacters(in: .whitespacesAndNewlines)
      )
    }
  }
}
