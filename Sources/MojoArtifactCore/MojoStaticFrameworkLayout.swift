import Foundation
import MojoBindingCore

package enum MojoStaticFrameworkLayout {
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
            to: frameworkURL.appendingPathComponent("Info.plist"),
            options: .atomic
        )
    }
}
