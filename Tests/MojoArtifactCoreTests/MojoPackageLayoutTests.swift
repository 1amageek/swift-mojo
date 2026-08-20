import Foundation
import MojoArtifactCore
import Testing

@Suite("SwiftPM package layout")
struct MojoPackageLayoutTests {
    @Test(.timeLimit(.minutes(1)))
    func normalizedTargetNamesHaveDistinctArtifactIdentities() throws {
        let hyphenated = try MojoArtifactIdentity(targetName: "Model-Core")
        let underscored = try MojoArtifactIdentity(targetName: "Model_Core")

        #expect(hyphenated.moduleName != underscored.moduleName)
        #expect(hyphenated.artifactName != underscored.artifactName)
        #expect(hyphenated.symbolPrefix != underscored.symbolPrefix)
    }

    @Test(.timeLimit(.minutes(1)))
    func discoversRecursiveSwiftSourcesInStableOrder() throws {
        try withPackageFixture { root in
            let nested = root.appendingPathComponent(
                "Sources/Application/Nested",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: nested,
                withIntermediateDirectories: true
            )
            let second = nested.appendingPathComponent("Second.swift")
            let first = root.appendingPathComponent(
                "Sources/Application/First.swift"
            )
            try "func second() {}".write(
                to: second,
                atomically: true,
                encoding: .utf8
            )
            try "func first() {}".write(
                to: first,
                atomically: true,
                encoding: .utf8
            )
            try "ignored".write(
                to: nested.appendingPathComponent("Notes.txt"),
                atomically: true,
                encoding: .utf8
            )

            let layout = try MojoPackageLayout(
                packageRootURL: root,
                targetName: "Application"
            )

            let sources = try layout.sourceURLs()
            #expect(sources.map(\.lastPathComponent) == [
                "First.swift",
                "Second.swift",
            ])
            #expect(sources[0].path.hasSuffix("/Sources/Application/First.swift"))
            #expect(
                sources[1].path.hasSuffix(
                    "/Sources/Application/Nested/Second.swift"
                )
            )
            #expect(
                layout.binaryTargetRelativePath
                    == "Generated/Application/SwiftMojo_Application_ABI.xcframework"
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingPackageManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Application"),
            withIntermediateDirectories: true
        )
        defer { removeFixture(root) }
        let layout = try MojoPackageLayout(
            packageRootURL: root,
            targetName: "Application"
        )

        #expect(throws: MojoArtifactError.self) {
            try layout.validatePackageTarget()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnsafeTargetName() {
        #expect(throws: MojoArtifactError.self) {
            _ = try MojoPackageLayout(
                packageRootURL: URL(fileURLWithPath: "/tmp/package"),
                targetName: "../Application"
            )
        }
    }

    private func withPackageFixture(
        _ body: (URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources/Application"),
            withIntermediateDirectories: true
        )
        try "// swift-tools-version: 6.2".write(
            to: root.appendingPathComponent("Package.swift"),
            atomically: true,
            encoding: .utf8
        )
        defer { removeFixture(root) }
        try body(root)
    }
}

private func removeFixture(_ root: URL) {
    do {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    } catch {
        Issue.record("Failed to remove package fixture: \(error)")
    }
}
