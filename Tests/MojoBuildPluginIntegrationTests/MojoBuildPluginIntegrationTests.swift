#if os(macOS) && arch(arm64)
import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import Testing

private struct IntegrationProcessResult: Sendable {
    let status: Int32
    let output: String
}

@Test(.timeLimit(.minutes(4)))
func pluginVerifiesStaticArtifactAndExactSyntaxRuns() throws {
    let fileManager = FileManager.default
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fileManager.createDirectory(
        at: temporaryRoot,
        withIntermediateDirectories: true
    )
    defer {
        do {
            try fileManager.removeItem(at: temporaryRoot)
        } catch {
            Issue.record("Failed to remove plugin fixture: \(error)")
        }
    }

    let sourceDirectory = temporaryRoot
        .appendingPathComponent("Sources/StaticMojoFixture", isDirectory: true)
    let generatedDirectory = temporaryRoot
        .appendingPathComponent("Generated/StaticMojoFixture", isDirectory: true)
    try fileManager.createDirectory(
        at: sourceDirectory,
        withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
        at: generatedDirectory,
        withIntermediateDirectories: true
    )
    let sourceURL = sourceDirectory.appendingPathComponent("Application.swift")
    try fixtureSource.write(to: sourceURL, atomically: true, encoding: .utf8)
    try packageManifest(packageRoot: packageRoot).write(
        to: temporaryRoot.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )
    try createStaticFixtureArtifact(
        sourceURL: sourceURL,
        outputDirectory: generatedDirectory
    )

    let log = temporaryRoot.appendingPathComponent("build.log")
    let scratch = temporaryRoot.appendingPathComponent("scratch", isDirectory: true)
    var environment = ProcessInfo.processInfo.environment
    environment.removeValue(forKey: "TOOLCHAINS")
    let build = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: environment,
        logURL: log
    )
    try #require(build.status == 0, "Fixture build failed:\n\(build.output)")

    let executable = try #require(
        try executableURL(under: scratch),
        "The fixture executable was not produced"
    )
    let execution = try runProcess(
        executablePath: executable.path,
        arguments: [],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("run.log")
    )
    #expect(execution.status == 0)
    #expect(execution.output.trimmingCharacters(in: .whitespacesAndNewlines) == "42")

    let overflow = try runProcess(
        executablePath: executable.path,
        arguments: ["--overflow"],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("overflow.log")
    )
    #expect(overflow.status != 0)
    #expect(overflow.output.contains("Int32 addition overflowed"))

    let artifactURL = generatedDirectory.appendingPathComponent(
        MojoStaticABI.artifactName,
        isDirectory: true
    )
    let headerURL = try requiredDescendant(
        named: "GeneratedMojoABI.h",
        under: artifactURL
    )
    let originalHeader = try Data(contentsOf: headerURL)
    try Data("corrupt header".utf8).write(to: headerURL)
    let corruptHeader = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("corrupt-header.log")
    )
    #expect(corruptHeader.status != 0)
    #expect(corruptHeader.output.contains("artifact digest is stale or corrupt"))
    try originalHeader.write(to: headerURL, options: .atomic)

    let archiveURL = try #require(
        try MojoArtifactVerifier.archiveURLs(in: artifactURL).first,
        "The fixture archive was not produced"
    )
    let originalArchive = try Data(contentsOf: archiveURL)
    try Data("corrupt archive".utf8).write(to: archiveURL)
    let corruptArchive = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("corrupt-archive.log")
    )
    #expect(corruptArchive.status != 0)
    #expect(corruptArchive.output.contains("artifact digest is stale or corrupt"))
    try originalArchive.write(to: archiveURL, options: .atomic)

    var wrongTargetEnvironment = environment
    wrongTargetEnvironment["SWIFT_MOJO_TARGET_TRIPLE"] = "arm64-apple-macosx15.0"
    let wrongTarget = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: wrongTargetEnvironment,
        logURL: temporaryRoot.appendingPathComponent("wrong-target.log")
    )
    #expect(wrongTarget.status != 0)
    #expect(wrongTarget.output.contains("does not match the Swift destination"))

    let manifestURL = generatedDirectory.appendingPathComponent(
        MojoStaticABI.manifestName
    )
    let manifestData = try Data(contentsOf: manifestURL)
    try fileManager.removeItem(at: manifestURL)
    let missingManifest = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("missing-manifest.log")
    )
    #expect(missingManifest.status != 0)
    #expect(missingManifest.output.contains(MojoStaticABI.manifestName))
    try manifestData.write(to: manifestURL, options: .atomic)

    try staleFixtureSource.write(
        to: sourceURL,
        atomically: true,
        encoding: .utf8
    )
    let stale = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: environment,
        logURL: temporaryRoot.appendingPathComponent("stale.log")
    )
    #expect(stale.status != 0)
    #expect(stale.output.contains("Prepared Mojo sources are stale"))
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment["SWIFT_MOJO_REAL_ACCEPTANCE"] == "1"
    ),
    .timeLimit(.minutes(8))
)
func realMojoCompilerPreparesBuildsAndRunsExactSyntax() throws {
    let fileManager = FileManager.default
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let temporaryRoot = fileManager.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let sourceDirectory = temporaryRoot
        .appendingPathComponent("Sources/StaticMojoFixture", isDirectory: true)
    let generatedDirectory = temporaryRoot
        .appendingPathComponent("Generated/StaticMojoFixture", isDirectory: true)
    try fileManager.createDirectory(
        at: sourceDirectory,
        withIntermediateDirectories: true
    )
    defer {
        do {
            try fileManager.removeItem(at: temporaryRoot)
        } catch {
            Issue.record("Failed to remove real Mojo fixture: \(error)")
        }
    }

    let sourceURL = sourceDirectory.appendingPathComponent("Application.swift")
    try fixtureSource.write(to: sourceURL, atomically: true, encoding: .utf8)
    try packageManifest(packageRoot: packageRoot).write(
        to: temporaryRoot.appendingPathComponent("Package.swift"),
        atomically: true,
        encoding: .utf8
    )

    let prepareResult = try MojoArtifactPreparer(
        environment: ProcessInfo.processInfo.environment
    ).prepare(
        options: MojoPrepareOptions(
            sourceURLs: [sourceURL],
            outputDirectoryURL: generatedDirectory,
            targetTriple: "arm64-apple-macosx14.0",
            targetCPU: "generic"
        )
    )
    #expect(prepareResult.disposition == .prepared)

    var buildEnvironment = ProcessInfo.processInfo.environment
    buildEnvironment.removeValue(forKey: "TOOLCHAINS")
    let scratch = temporaryRoot.appendingPathComponent("scratch", isDirectory: true)
    let build = try runProcess(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "swift",
            "build",
            "--package-path", temporaryRoot.path,
            "--scratch-path", scratch.path,
        ],
        environment: buildEnvironment,
        logURL: temporaryRoot.appendingPathComponent("real-mojo-build.log")
    )
    try #require(build.status == 0, "Real Mojo fixture build failed:\n\(build.output)")

    let executable = try #require(
        try executableURL(under: scratch),
        "The real Mojo fixture executable was not produced"
    )
    let execution = try runProcess(
        executablePath: executable.path,
        arguments: [],
        environment: buildEnvironment,
        logURL: temporaryRoot.appendingPathComponent("real-mojo-run.log")
    )
    #expect(execution.status == 0)
    #expect(execution.output.trimmingCharacters(in: .whitespacesAndNewlines) == "42")

    let overflow = try runProcess(
        executablePath: executable.path,
        arguments: ["--overflow"],
        environment: buildEnvironment,
        logURL: temporaryRoot.appendingPathComponent("real-mojo-overflow.log")
    )
    #expect(overflow.status != 0)
    #expect(overflow.output.contains("Int32 addition overflowed"))
}

private var fixtureSource: String {
    """
    import Mojo

    @mojo
    func add(_ a: Int32, _ b: Int32) -> Int32 {
        mojo {
            return a + b
        }
    }

    @main
    enum Application {
        static func main() {
            if CommandLine.arguments.contains("--overflow") {
                print(add(Int32.max, 1))
                return
            }
            print(add(20, 22))
        }
    }
    """ + "\n"
}

private var staleFixtureSource: String {
    """
    import Mojo

    @mojo
    func add(_ a: Int32, _ b: Int32) -> Int32 {
        mojo {
            return b + a
        }
    }

    @main
    enum Application {
        static func main() {
            if CommandLine.arguments.contains("--overflow") {
                print(add(Int32.max, 1))
                return
            }
            print(add(20, 22))
        }
    }
    """ + "\n"
}

private func packageManifest(packageRoot: URL) -> String {
    let escapedRoot = packageRoot.path
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    return """
    // swift-tools-version: 6.2
    import PackageDescription

    let package = Package(
        name: "StaticMojoFixture",
        platforms: [.macOS(.v14)],
        dependencies: [
            .package(name: "swift-mojo", path: "\(escapedRoot)"),
        ],
        targets: [
            .binaryTarget(
                name: "GeneratedMojoABI",
                path: "Generated/StaticMojoFixture/GeneratedMojoABI.xcframework"
            ),
            .executableTarget(
                name: "StaticMojoFixture",
                dependencies: [
                    .product(name: "Mojo", package: "swift-mojo"),
                    "GeneratedMojoABI",
                ],
                plugins: [
                    .plugin(name: "MojoBuildPlugin", package: "swift-mojo"),
                ]
            ),
        ]
    )
    """ + "\n"
}

private func createStaticFixtureArtifact(
    sourceURL: URL,
    outputDirectory: URL
) throws {
    let graph = try MojoSourceGraph(sourceURLs: [sourceURL])
    let binding = try #require(graph.bindings.first)
    let renderer = MojoStaticSourceRenderer()
    let headers = outputDirectory.appendingPathComponent("include", isDirectory: true)
    let object = outputDirectory.appendingPathComponent("Bindings.o")
    let archive = outputDirectory.appendingPathComponent(MojoStaticABI.libraryName)
    let artifact = outputDirectory.appendingPathComponent(
        MojoStaticABI.artifactName,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: headers,
        withIntermediateDirectories: true
    )
    try renderer.header.write(
        to: headers.appendingPathComponent("GeneratedMojoABI.h"),
        atomically: true,
        encoding: .utf8
    )
    try renderer.moduleMap.write(
        to: headers.appendingPathComponent("module.modulemap"),
        atomically: true,
        encoding: .utf8
    )
    let cSource = outputDirectory.appendingPathComponent("Bindings.c")
    let c = """
    #include <stdint.h>
    uint32_t swift_mojo_static_abi_version(void) { return \(MojoStaticABI.version); }
    uint64_t swift_mojo_source_graph_identifier(void) { return \(graph.digestIdentifier)ULL; }
    uint32_t swift_mojo_has_binding(uint64_t binding_id) {
        return binding_id == \(binding.bindingID)ULL ? 1 : 0;
    }
    int32_t swift_mojo_call_i32_i32_i32(uint64_t binding_id, int32_t lhs, int32_t rhs) {
        if (binding_id != \(binding.bindingID)ULL) { __builtin_trap(); }
        return lhs + rhs;
    }
    """ + "\n"
    try c.write(to: cSource, atomically: true, encoding: .utf8)
    try runSynchronous(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "clang", "-arch", "arm64", "-mmacosx-version-min=14.0",
            "-c", cSource.path, "-o", object.path,
        ]
    )
    try runSynchronous(
        executablePath: "/usr/bin/ar",
        arguments: ["rcs", archive.path, object.path]
    )
    try runSynchronous(
        executablePath: "/usr/bin/xcrun",
        arguments: [
            "xcodebuild", "-create-xcframework",
            "-library", archive.path,
            "-headers", headers.path,
            "-output", artifact.path,
        ]
    )
    let target = try MojoTargetConfiguration(
        triple: "arm64-apple-macosx14.0",
        cpu: "generic"
    )
    let manifest = MojoArtifactManifest(
        compilerVersion: "C integration fixture",
        target: target,
        sourceGraph: graph,
        artifactDigest: try MojoCanonicalDigest.tree(at: artifact)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(manifest).write(
        to: outputDirectory.appendingPathComponent(MojoStaticABI.manifestName),
        options: .atomic
    )
}

private func runSynchronous(
    executablePath: String,
    arguments: [String]
) throws {
    let result = try FoundationMojoProcessRunner(
        timeoutSeconds: 100,
        terminationGraceSeconds: 2
    ).capture(executablePath: executablePath, arguments: arguments)
    guard result.status == 0 else {
        throw MojoArtifactError.commandFailed(
            command: ([executablePath] + arguments).joined(separator: " "),
            status: result.status,
            diagnostic: result.output
        )
    }
}

private func runProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String],
    logURL: URL
) throws -> IntegrationProcessResult {
    let result = try FoundationMojoProcessRunner(
        environment: environment,
        timeoutSeconds: 100,
        terminationGraceSeconds: 2
    ).capture(executablePath: executablePath, arguments: arguments)
    try Data(result.output.utf8).write(to: logURL, options: .atomic)
    return IntegrationProcessResult(
        status: result.status,
        output: result.output
    )
}

private func requiredDescendant(named name: String, under root: URL) throws -> URL {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw MojoArtifactError.artifactMissing(root.path)
    }
    for case let url as URL in enumerator where url.lastPathComponent == name {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        if values.isRegularFile == true { return url }
    }
    throw MojoArtifactError.artifactMissing(
        root.appendingPathComponent(name).path
    )
}

private func executableURL(under root: URL) throws -> URL? {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isExecutableKey, .isRegularFileKey]
    ) else {
        return nil
    }
    for case let url as URL in enumerator
    where url.lastPathComponent == "StaticMojoFixture" {
        let values = try url.resourceValues(
            forKeys: [.isExecutableKey, .isRegularFileKey]
        )
        if values.isExecutable == true && values.isRegularFile == true {
            return url
        }
    }
    return nil
}
#endif
