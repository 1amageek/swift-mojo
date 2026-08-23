import Foundation
import MojoBindingCore

package enum MojoStaticFrameworkLayout {
  package enum Style: Equatable, Sendable {
    case shallow
    case versioned
  }

  package static func frameworkName(
    identity: MojoArtifactIdentity
  ) -> String {
    "\(identity.moduleName).framework"
  }

  package static func frameworkURL(
    in sliceURL: URL,
    identity: MojoArtifactIdentity
  ) -> URL {
    sliceURL.appendingPathComponent(
      frameworkName(identity: identity),
      isDirectory: true
    )
  }

  package static func binaryURL(
    in sliceURL: URL,
    identity: MojoArtifactIdentity
  ) -> URL {
    frameworkURL(in: sliceURL, identity: identity)
      .appendingPathComponent(identity.moduleName)
  }

  package static func headersURL(
    in frameworkURL: URL
  ) -> URL {
    frameworkURL.appendingPathComponent("Headers", isDirectory: true)
  }

  package static func modulesURL(
    in frameworkURL: URL
  ) -> URL {
    frameworkURL.appendingPathComponent("Modules", isDirectory: true)
  }

  package static func informationPropertyListURL(
    in frameworkURL: URL,
    style: Style
  ) -> URL {
    switch style {
    case .shallow:
      frameworkURL.appendingPathComponent("Info.plist")
    case .versioned:
      frameworkURL
        .appendingPathComponent("Versions/Current/Resources")
        .appendingPathComponent("Info.plist")
    }
  }

  package static func style(forApplePlatform platform: String) -> Style {
    platform == "macos" ? .versioned : .shallow
  }

  package static func binaryPath(
    identity: MojoArtifactIdentity,
    style: Style
  ) -> String {
    let framework = frameworkName(identity: identity)
    switch style {
    case .shallow:
      return "\(framework)/\(identity.moduleName)"
    case .versioned:
      return "\(framework)/Versions/A/\(identity.moduleName)"
    }
  }

  package static func allowedSymbolicLinks(
    identity: MojoArtifactIdentity,
    slices: [MojoArtifactManifest.Slice]
  ) throws -> [String: String] {
    var result: [String: String] = [:]
    for slice in slices {
      let selector = try MojoXCFrameworkSliceIdentity(
        target: slice.target
      )
      guard style(forApplePlatform: selector.platform) == .versioned else {
        continue
      }
      let prefix = [
        slice.libraryIdentifier,
        frameworkName(identity: identity),
      ].joined(separator: "/")
      result["\(prefix)/Versions/Current"] = "A"
      for component in ["Headers", "Modules", "Resources"] {
        result["\(prefix)/\(component)"] =
          "Versions/Current/\(component)"
      }
      result["\(prefix)/\(identity.moduleName)"] =
        "Versions/Current/\(identity.moduleName)"
    }
    return result
  }

  package static func validateFramework(
    at frameworkURL: URL,
    identity: MojoArtifactIdentity,
    style: Style
  ) throws {
    switch style {
    case .shallow:
      try requireRegularFiles([
        frameworkURL.appendingPathComponent(identity.moduleName),
        headersURL(in: frameworkURL).appendingPathComponent(
          "\(identity.moduleName).h"
        ),
        modulesURL(in: frameworkURL).appendingPathComponent(
          "module.modulemap"
        ),
        informationPropertyListURL(
          in: frameworkURL,
          style: .shallow
        ),
      ])
      let versionsURL = frameworkURL.appendingPathComponent("Versions")
      guard !FileManager.default.fileExists(atPath: versionsURL.path) else {
        throw MojoArtifactError.xcframeworkMetadataMismatch(
          "Shallow framework contains a Versions directory"
        )
      }
    case .versioned:
      let versionURL = frameworkURL.appendingPathComponent(
        "Versions/A",
        isDirectory: true
      )
      try requireRegularFiles([
        versionURL.appendingPathComponent(identity.moduleName),
        versionURL.appendingPathComponent(
          "Headers/\(identity.moduleName).h"
        ),
        versionURL.appendingPathComponent("Modules/module.modulemap"),
        versionURL.appendingPathComponent("Resources/Info.plist"),
      ])
      let rootInformation = frameworkURL.appendingPathComponent(
        "Info.plist"
      )
      guard
        !FileManager.default.fileExists(
          atPath: rootInformation.path
        )
      else {
        throw MojoArtifactError.xcframeworkMetadataMismatch(
          "Versioned framework contains a root Info.plist"
        )
      }
      try requireSymbolicLink(
        frameworkURL.appendingPathComponent("Versions/Current"),
        destination: "A"
      )
      for component in ["Headers", "Modules", "Resources"] {
        try requireSymbolicLink(
          frameworkURL.appendingPathComponent(component),
          destination: "Versions/Current/\(component)"
        )
      }
      try requireSymbolicLink(
        frameworkURL.appendingPathComponent(identity.moduleName),
        destination: "Versions/Current/\(identity.moduleName)"
      )
    }
  }

  package static func informationPropertyList(
    identity: MojoArtifactIdentity
  ) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": identity.moduleName,
        "CFBundleIdentifier": "dev.swift-mojo.abi.\(MojoCanonicalDigest.hex(identity.targetName))",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": identity.moduleName,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
      ],
      format: .xml,
      options: 0
    )
  }

  package static func createFramework(
    at frameworkURL: URL,
    identity: MojoArtifactIdentity,
    archiveURL: URL,
    header: String,
    moduleMap: String,
    style: Style
  ) throws {
    switch style {
    case .shallow:
      try createShallowFramework(
        at: frameworkURL,
        identity: identity,
        archiveURL: archiveURL,
        header: header,
        moduleMap: moduleMap
      )
    case .versioned:
      try createVersionedFramework(
        at: frameworkURL,
        identity: identity,
        archiveURL: archiveURL,
        header: header,
        moduleMap: moduleMap
      )
    }
  }

  private static func createShallowFramework(
    at frameworkURL: URL,
    identity: MojoArtifactIdentity,
    archiveURL: URL,
    header: String,
    moduleMap: String
  ) throws {
    let headersURL = headersURL(in: frameworkURL)
    let modulesURL = modulesURL(in: frameworkURL)
    try FileManager.default.createDirectory(
      at: headersURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: modulesURL,
      withIntermediateDirectories: true
    )
    try FileManager.default.copyItem(
      at: archiveURL,
      to: frameworkURL.appendingPathComponent(identity.moduleName)
    )
    try header.write(
      to: headersURL.appendingPathComponent("\(identity.moduleName).h"),
      atomically: true,
      encoding: .utf8
    )
    try moduleMap.write(
      to: modulesURL.appendingPathComponent("module.modulemap"),
      atomically: true,
      encoding: .utf8
    )
    try informationPropertyList(identity: identity).write(
      to: informationPropertyListURL(
        in: frameworkURL,
        style: .shallow
      ),
      options: .atomic
    )
  }

  private static func createVersionedFramework(
    at frameworkURL: URL,
    identity: MojoArtifactIdentity,
    archiveURL: URL,
    header: String,
    moduleMap: String
  ) throws {
    let versionURL = frameworkURL.appendingPathComponent(
      "Versions/A",
      isDirectory: true
    )
    let headersURL = versionURL.appendingPathComponent(
      "Headers",
      isDirectory: true
    )
    let modulesURL = versionURL.appendingPathComponent(
      "Modules",
      isDirectory: true
    )
    let resourcesURL = versionURL.appendingPathComponent(
      "Resources",
      isDirectory: true
    )
    for directory in [headersURL, modulesURL, resourcesURL] {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
    }
    try FileManager.default.copyItem(
      at: archiveURL,
      to: versionURL.appendingPathComponent(identity.moduleName)
    )
    try header.write(
      to: headersURL.appendingPathComponent("\(identity.moduleName).h"),
      atomically: true,
      encoding: .utf8
    )
    try moduleMap.write(
      to: modulesURL.appendingPathComponent("module.modulemap"),
      atomically: true,
      encoding: .utf8
    )
    try informationPropertyList(identity: identity).write(
      to: resourcesURL.appendingPathComponent("Info.plist"),
      options: .atomic
    )
    try createRelativeSymbolicLink(
      at: frameworkURL.appendingPathComponent("Versions/Current"),
      destination: "A"
    )
    for component in ["Headers", "Modules", "Resources"] {
      try createRelativeSymbolicLink(
        at: frameworkURL.appendingPathComponent(component),
        destination: "Versions/Current/\(component)"
      )
    }
    try createRelativeSymbolicLink(
      at: frameworkURL.appendingPathComponent(identity.moduleName),
      destination: "Versions/Current/\(identity.moduleName)"
    )
  }

  private static func createRelativeSymbolicLink(
    at url: URL,
    destination: String
  ) throws {
    try FileManager.default.createSymbolicLink(
      atPath: url.path,
      withDestinationPath: destination
    )
  }

  private static func requireRegularFiles(_ urls: [URL]) throws {
    for url in urls where !MojoRegularFile.isValid(at: url) {
      throw MojoArtifactError.artifactInterfaceMissing(url.path)
    }
  }

  private static func requireSymbolicLink(
    _ url: URL,
    destination: String
  ) throws {
    let actual: String
    do {
      actual = try FileManager.default.destinationOfSymbolicLink(
        atPath: url.path
      )
    } catch {
      throw MojoArtifactError.xcframeworkMetadataMismatch(
        "Required framework symbolic link is missing at '\(url.path)'"
      )
    }
    guard actual == destination else {
      throw MojoArtifactError.xcframeworkMetadataMismatch(
        "Framework symbolic link '\(url.path)' targets '\(actual)' instead of '\(destination)'"
      )
    }
  }
}
