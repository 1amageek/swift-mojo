import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

private struct BundleObjectRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == "/usr/bin/nm",
              arguments.count == 2,
              arguments[0] == "-u" else {
            throw MojoArtifactError.invalidArguments(
                "Unexpected bundle object command"
            )
        }
        return MojoProcessResult(
            status: 0,
            output: """
            _AsyncRT_DeviceContext_create
            _KGEN_CompilerRT_AlignedAlloc
            _memcpy
            """
        )
    }
}

private struct BundleBinaryInspector: MojoRuntimeBinaryInspecting {
    let libraries: [String: MojoRuntimeBinaryInspection]
    let executable: MojoRuntimeExecutableInspection

    func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {}

    func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        guard let inspection = libraries[libraryURL.lastPathComponent] else {
            throw MojoArtifactError.invalidArguments(
                "Missing bundle library inspection fixture"
            )
        }
        return inspection
    }

    func inspectExecutable(
        executableURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeExecutableInspection {
        executable
    }
}

private struct BundleExecutableLinker: MojoRuntimeExecutableLinking {
    func link(
        objectURL: URL,
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String]
    ) throws {
        try Data("linked runtime executable".utf8).write(to: outputURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: outputURL.path
        )
    }
}

@Suite("Mojo runtime worker bundles")
struct MojoRuntimeBundleTests {
    @Test(.timeLimit(.minutes(1)))
    func preparesAndVerifiesExactBundle() throws {
        try withBundleFixture { fixture in
            let manifest = try fixture.builder().prepare(
                receipt: fixture.receipt,
                options: fixture.options()
            )

            #expect(manifest.receiptDigest == fixture.receipt.digest)
            #expect(manifest.loaderSearchPath == "@executable_path/../lib")
            #expect(manifest.executable.relativePath == "bin/mojo-worker")
            #expect(
                manifest.libraries.map(\.relativePath) == [
                    "lib/libGlobals.dylib",
                    "lib/libRuntime.dylib",
                ]
            )
            #expect(
                manifest.systemDependencies
                    == ["/usr/lib/libSystem.B.dylib"]
            )
            #expect(manifest.digest.count == 64)
            #expect(
                try fixture.verifier().verify(bundleURL: fixture.outputURL)
                    == manifest
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verificationRejectsChangedExecutable() throws {
        try withBundleFixture { fixture in
            _ = try fixture.builder().prepare(
                receipt: fixture.receipt,
                options: fixture.options()
            )
            try Data("changed executable".utf8).write(
                to: fixture.outputURL.appendingPathComponent(
                    "bin/mojo-worker"
                )
            )

            do {
                _ = try fixture.verifier().verify(
                    bundleURL: fixture.outputURL
                )
                Issue.record("Changed runtime executable unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .invalidRuntimeBundle(let detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("executable digest"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verificationRejectsUnexpectedBundleEntry() throws {
        try withBundleFixture { fixture in
            _ = try fixture.builder().prepare(
                receipt: fixture.receipt,
                options: fixture.options()
            )
            try Data("ambient".utf8).write(
                to: fixture.outputURL.appendingPathComponent("ambient.dylib")
            )

            #expect(throws: (any Error).self) {
                _ = try fixture.verifier().verify(
                    bundleURL: fixture.outputURL
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verificationRejectsNonExecutableWorker() throws {
        try withBundleFixture { fixture in
            _ = try fixture.builder().prepare(
                receipt: fixture.receipt,
                options: fixture.options()
            )
            let executable = fixture.outputURL.appendingPathComponent(
                "bin/mojo-worker"
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: executable.path
            )

            do {
                _ = try fixture.verifier().verify(
                    bundleURL: fixture.outputURL
                )
                Issue.record("Non-executable runtime worker verified")
            } catch let error as MojoArtifactError {
                guard case .invalidRuntimeBundle(let detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("is not executable"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func linkingRejectsMissingDeclaredRuntimeDependency() throws {
        try withBundleFixture { fixture in
            let incomplete = MojoRuntimeExecutableInspection(
                architecture: "arm64",
                dynamicDependencies: [
                    "/usr/lib/libSystem.B.dylib",
                    "@rpath/libRuntime.dylib",
                ],
                runtimeSearchPaths: ["@executable_path/../lib"],
                programInterpreter: nil
            )

            do {
                _ = try fixture.builder(
                    executableInspection: incomplete
                ).prepare(
                    receipt: fixture.receipt,
                    options: fixture.options()
                )
                Issue.record("Incomplete executable dependency set linked")
            } catch let error as MojoArtifactError {
                guard case .invalidRuntimeBundle(let detail) = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(detail.contains("runtime dependencies"))
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func loaderPolicyRejectsAmbientInstallName() throws {
        try withBundleFixture { fixture in
            let invalid = MojoRuntimeDependencyReceipt(
                target: fixture.receipt.target,
                objectDigest: fixture.receipt.objectDigest,
                requiredSymbols: fixture.receipt.requiredSymbols,
                systemDependencies: fixture.receipt.systemDependencies,
                libraries: fixture.receipt.libraries.map { library in
                    guard library.fileName == "libRuntime.dylib" else {
                        return library
                    }
                    return MojoRuntimeDependencyReceipt.Library(
                        fileName: library.fileName,
                        digest: library.digest,
                        architecture: library.architecture,
                        installName: "/tmp/libRuntime.dylib",
                        dynamicDependencies: library.dynamicDependencies,
                        providedSymbols: library.providedSymbols
                    )
                }
            )

            #expect(throws: (any Error).self) {
                try MojoRuntimeLoaderPolicy.validate(receipt: invalid)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func optionsRejectInputsInsideOutputDirectory() throws {
        try withBundleFixture { fixture in
            let output = fixture.root.appendingPathComponent(
                "containing-bundle",
                isDirectory: true
            )
            let object = output.appendingPathComponent("Bindings.o")

            #expect(throws: (any Error).self) {
                _ = try MojoRuntimeBundleOptions(
                    outputDirectoryURL: output,
                    executableName: "mojo-worker",
                    objectURL: object,
                    libraryURLs: fixture.libraryURLs,
                    target: fixture.target
                )
            }
        }
    }
}

private struct RuntimeBundleFixture {
    let root: URL
    let objectURL: URL
    let libraryURLs: [URL]
    let outputURL: URL
    let target: MojoTargetConfiguration
    let libraries: [String: MojoRuntimeBinaryInspection]
    let executableInspection: MojoRuntimeExecutableInspection
    let receipt: MojoRuntimeDependencyReceipt

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        objectURL = root.appendingPathComponent("Bindings.o")
        libraryURLs = [
            root.appendingPathComponent("libGlobals.dylib"),
            root.appendingPathComponent("libRuntime.dylib"),
        ]
        outputURL = root.appendingPathComponent(
            "Runtime.bundle",
            isDirectory: true
        )
        try Data("runtime object".utf8).write(to: objectURL)
        for (index, url) in libraryURLs.enumerated() {
            try Data("runtime library \(index)".utf8).write(to: url)
        }
        target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "apple-gpu"
        )
        libraries = [
            "libGlobals.dylib": MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/libGlobals.dylib",
                dynamicDependencies: ["/usr/lib/libSystem.B.dylib"],
                exportedSymbols: []
            ),
            "libRuntime.dylib": MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/libRuntime.dylib",
                dynamicDependencies: [
                    "/usr/lib/libSystem.B.dylib",
                    "@rpath/libGlobals.dylib",
                ],
                exportedSymbols: [
                    "AsyncRT_DeviceContext_create",
                    "KGEN_CompilerRT_AlignedAlloc",
                ]
            ),
        ]
        executableInspection = MojoRuntimeExecutableInspection(
            architecture: "arm64",
            dynamicDependencies: [
                "/usr/lib/libSystem.B.dylib",
                "@rpath/libGlobals.dylib",
                "@rpath/libRuntime.dylib",
            ],
            runtimeSearchPaths: ["@executable_path/../lib"],
            programInterpreter: nil
        )
        let preparer = Self.preparer(
            libraries: libraries,
            executableInspection: executableInspection
        )
        receipt = try preparer.prepare(
            options: MojoRuntimeReceiptOptions(
                objectURL: objectURL,
                libraryURLs: libraryURLs,
                target: target
            )
        )
    }

    func options() throws -> MojoRuntimeBundleOptions {
        try MojoRuntimeBundleOptions(
            outputDirectoryURL: outputURL,
            executableName: "mojo-worker",
            objectURL: objectURL,
            libraryURLs: libraryURLs,
            target: target
        )
    }

    func builder(
        executableInspection: MojoRuntimeExecutableInspection? = nil
    ) -> MojoRuntimeBundleBuilder {
        let inspection = executableInspection ?? self.executableInspection
        let preparer = Self.preparer(
            libraries: libraries,
            executableInspection: inspection
        )
        return MojoRuntimeBundleBuilder(
            linker: BundleExecutableLinker(),
            receiptVerifier: MojoRuntimeReceiptVerifier(preparer: preparer),
            bundleVerifier: verifier(
                executableInspection: inspection
            )
        )
    }

    func verifier(
        executableInspection: MojoRuntimeExecutableInspection? = nil
    ) -> MojoRuntimeBundleVerifier {
        let inspection = executableInspection ?? self.executableInspection
        return MojoRuntimeBundleVerifier(
            binaryInspector: BundleBinaryInspector(
                libraries: libraries,
                executable: inspection
            ),
            processRunner: BundleObjectRunner()
        )
    }

    private static func preparer(
        libraries: [String: MojoRuntimeBinaryInspection],
        executableInspection: MojoRuntimeExecutableInspection
    ) -> MojoRuntimeReceiptPreparer {
        MojoRuntimeReceiptPreparer(
            binaryInspector: BundleBinaryInspector(
                libraries: libraries,
                executable: executableInspection
            ),
            processRunner: BundleObjectRunner()
        )
    }
}

private func withBundleFixture(
    _ body: (RuntimeBundleFixture) throws -> Void
) throws {
    let fixture = try RuntimeBundleFixture()
    defer {
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            Issue.record("Failed to remove runtime bundle fixture: \(error)")
        }
    }
    try body(fixture)
}
