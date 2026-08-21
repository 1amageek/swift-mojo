import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

private struct FixtureRuntimeObjectRunner: MojoProcessRunning {
    let undefinedSymbols: [String]

    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == "/usr/bin/nm",
              arguments.count == 2,
              arguments[0] == "-u" else {
            throw MojoArtifactError.invalidArguments(
                "Unexpected runtime object command"
            )
        }
        return MojoProcessResult(
            status: 0,
            output: undefinedSymbols.joined(separator: "\n")
        )
    }
}

private struct FixtureRuntimeBinaryInspector: MojoRuntimeBinaryInspecting {
    let inspections: [String: MojoRuntimeBinaryInspection]
    let objectArchitecture: String

    func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        guard objectArchitecture == "arm64" else {
            throw MojoArtifactError.runtimeObjectArchitectureMismatch(
                expected: "arm64",
                actual: objectArchitecture
            )
        }
    }

    func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        guard let inspection = inspections[libraryURL.lastPathComponent] else {
            throw MojoArtifactError.invalidArguments(
                "Missing runtime inspection fixture"
            )
        }
        return inspection
    }
}

private struct FixtureRuntimeMetadataRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        if executablePath == "/usr/bin/xcrun",
           arguments.first == "lipo" {
            return MojoProcessResult(status: 0, output: "arm64\n")
        }
        if executablePath == "/usr/bin/xcrun",
           arguments.first == "dyld_info" {
            return MojoProcessResult(
                status: 0,
                output: """
                [arm64]:
                -exports:
                        0x00001234  _AsyncRT_DeviceContext_create
                        0x00005678  _KGEN_CompilerRT_AlignedAlloc
                """
            )
        }
        if executablePath == "/usr/bin/otool" {
            return MojoProcessResult(
                status: 0,
                output: """
                /tmp/libRuntime.dylib:
                    @rpath/libRuntime.dylib (compatibility version 0.0.0, current version 0.0.0)
                    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)
                """
            )
        }
        if executablePath == "/tools/llvm-nm" {
            return MojoProcessResult(
                status: 0,
                output: """
                0000000000001234 T AsyncRT_DeviceContext_create
                0000000000005678 T KGEN_CompilerRT_AlignedAlloc@@MAX_1
                """
            )
        }
        if executablePath == "/tools/llvm-readelf" {
            return MojoProcessResult(
                status: 0,
                output: """
                  Machine:                           AArch64
                 0x000000000000000e (SONAME)             Library soname: [libRuntime.so]
                 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
                """
            )
        }
        throw MojoArtifactError.invalidArguments(
            "Unexpected runtime metadata command"
        )
    }
}

@Suite("Mojo runtime dependency receipts")
struct MojoRuntimeReceiptTests {
    @Test(.timeLimit(.minutes(1)))
    func preparesAndVerifiesExactRuntimeClosure() throws {
        try withRuntimeFixture { fixture in
            let preparer = fixture.preparer()
            let receipt = try preparer.prepare(options: fixture.options)

            #expect(
                receipt.requiredSymbols == [
                    "AsyncRT_DeviceContext_create",
                    "KGEN_CompilerRT_AlignedAlloc",
                ]
            )
            #expect(
                receipt.libraries.map(\.fileName) == [
                    "libAsyncRT.dylib",
                    "libGlobals.dylib",
                    "libKGEN.dylib",
                ]
            )
            #expect(
                receipt.systemDependencies == ["/usr/lib/libSystem.B.dylib"]
            )
            #expect(receipt.digest.count == 64)
            #expect(
                try MojoRuntimeDependencyReceipt.decode(receipt.encoded())
                    == receipt
            )
            #expect(
                try MojoRuntimeReceiptVerifier(preparer: preparer).verify(
                    receipt: receipt,
                    options: fixture.options
                ) == receipt
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingRuntimeSymbolProvider() throws {
        try withRuntimeFixture { fixture in
            let inspections = fixture.inspections.merging([
                "libKGEN.dylib": fixture.inspection(
                    installName: "@rpath/libKGEN.dylib",
                    dependencies: ["@rpath/libGlobals.dylib"],
                    exports: []
                ),
            ]) { _, replacement in replacement }
            let preparer = fixture.preparer(inspections: inspections)

            #expect(
                throws: MojoArtifactError.runtimeSymbolsUnresolved(
                    target: fixture.target.identity,
                    symbols: ["KGEN_CompilerRT_AlignedAlloc"]
                )
            ) {
                _ = try preparer.prepare(options: fixture.options)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsDuplicateRuntimeSymbolProviders() throws {
        try withRuntimeFixture { fixture in
            let inspections = fixture.inspections.merging([
                "libKGEN.dylib": fixture.inspection(
                    installName: "@rpath/libKGEN.dylib",
                    dependencies: ["@rpath/libGlobals.dylib"],
                    exports: [
                        "AsyncRT_DeviceContext_create",
                        "KGEN_CompilerRT_AlignedAlloc",
                    ]
                ),
            ]) { _, replacement in replacement }

            #expect(
                throws: MojoArtifactError.runtimeSymbolProviderConflict(
                    symbol: "AsyncRT_DeviceContext_create",
                    libraries: ["libAsyncRT.dylib", "libKGEN.dylib"]
                )
            ) {
                _ = try fixture.preparer(inspections: inspections).prepare(
                    options: fixture.options
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUndeclaredTransitiveRuntimeDependency() throws {
        try withRuntimeFixture { fixture in
            let inspections = fixture.inspections.merging([
                "libKGEN.dylib": fixture.inspection(
                    installName: "@rpath/libKGEN.dylib",
                    dependencies: ["@rpath/libMissing.dylib"],
                    exports: ["KGEN_CompilerRT_AlignedAlloc"]
                ),
            ]) { _, replacement in replacement }

            #expect(
                throws: MojoArtifactError.runtimeDependencyUnresolved(
                    library: "libKGEN.dylib",
                    dependency: "@rpath/libMissing.dylib"
                )
            ) {
                _ = try fixture.preparer(inspections: inspections).prepare(
                    options: fixture.options
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsUnreachableDeclaredRuntimeLibrary() throws {
        try withRuntimeFixture { fixture in
            let extraURL = fixture.root.appendingPathComponent(
                "libUnreachable.dylib"
            )
            try Data("unreachable runtime".utf8).write(to: extraURL)
            let options = try MojoRuntimeReceiptOptions(
                objectURL: fixture.objectURL,
                libraryURLs: fixture.libraryURLs + [extraURL],
                target: fixture.target
            )
            let inspections = fixture.inspections.merging([
                "libUnreachable.dylib": fixture.inspection(
                    installName: "@rpath/libUnreachable.dylib",
                    dependencies: [],
                    exports: []
                ),
            ]) { _, replacement in replacement }

            #expect(
                throws: MojoArtifactError.runtimeLibrariesUnreachable(
                    ["libUnreachable.dylib"]
                )
            ) {
                _ = try fixture.preparer(inspections: inspections).prepare(
                    options: options
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verificationRejectsChangedRuntimeLibrary() throws {
        try withRuntimeFixture { fixture in
            let preparer = fixture.preparer()
            let receipt = try preparer.prepare(options: fixture.options)
            try Data("changed runtime".utf8).write(
                to: fixture.libraryURLs[0]
            )

            do {
                _ = try MojoRuntimeReceiptVerifier(preparer: preparer).verify(
                    receipt: receipt,
                    options: fixture.options
                )
                Issue.record("Changed runtime library unexpectedly verified")
            } catch let error as MojoArtifactError {
                guard case .runtimeReceiptMismatch(let expected, let actual)
                    = error else {
                    Issue.record("Unexpected error: \(error)")
                    return
                }
                #expect(expected == receipt.digest)
                #expect(actual != expected)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsAmbientAppleRuntimeDependencyAllowance() throws {
        try withRuntimeFixture { fixture in
            #expect(
                throws: MojoArtifactError.invalidArguments(
                    "Explicit system dependencies are supported only for Linux SONAMEs"
                )
            ) {
                _ = try MojoRuntimeReceiptOptions(
                    objectURL: fixture.objectURL,
                    libraryURLs: fixture.libraryURLs,
                    target: fixture.target,
                    allowedSystemDependencies: ["@rpath/libAmbient.dylib"]
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsNoncanonicalAppleSystemDependencyPath() throws {
        try withRuntimeFixture { fixture in
            let inspections = fixture.inspections.merging([
                "libAsyncRT.dylib": fixture.inspection(
                    installName: "@rpath/libAsyncRT.dylib",
                    dependencies: ["/usr/lib/../tmp/libAmbient.dylib"],
                    exports: ["AsyncRT_DeviceContext_create"]
                ),
            ]) { _, replacement in replacement }

            #expect(
                throws: MojoArtifactError.runtimeDependencyUnresolved(
                    library: "libAsyncRT.dylib",
                    dependency: "/usr/lib/../tmp/libAmbient.dylib"
                )
            ) {
                _ = try fixture.preparer(inspections: inspections).prepare(
                    options: fixture.options
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsPathBasedLinuxSystemDependency() throws {
        try withRuntimeFixture { fixture in
            let target = try MojoTargetConfiguration(
                triple: "aarch64-unknown-linux-gnu",
                cpu: "cortex-a78ae",
                accelerator: "sm_87"
            )
            let options = try MojoRuntimeReceiptOptions(
                objectURL: fixture.objectURL,
                libraryURLs: fixture.libraryURLs,
                target: target,
                allowedSystemDependencies: ["libcuda.so.1"]
            )
            let inspections = fixture.inspections.merging([
                "libAsyncRT.dylib": fixture.inspection(
                    installName: "libAsyncRT.so",
                    dependencies: ["/tmp/libcuda.so.1"],
                    exports: ["AsyncRT_DeviceContext_create"]
                ),
            ]) { _, replacement in replacement }

            #expect(
                throws: MojoArtifactError.runtimeDependencyUnresolved(
                    library: "libAsyncRT.dylib",
                    dependency: "/tmp/libcuda.so.1"
                )
            ) {
                _ = try fixture.preparer(inspections: inspections).prepare(
                    options: options
                )
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsRuntimeObjectArchitectureMismatch() throws {
        try withRuntimeFixture { fixture in
            #expect(
                throws: MojoArtifactError.runtimeObjectArchitectureMismatch(
                    expected: "arm64",
                    actual: "x86_64"
                )
            ) {
                _ = try fixture.preparer(objectArchitecture: "x86_64")
                    .prepare(options: fixture.options)
            }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func parsesAppleRuntimeMetadata() throws {
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "apple-gpu"
        )
        let inspection = try MojoRuntimeBinaryInspector(
            processRunner: FixtureRuntimeMetadataRunner(),
            environment: [:]
        ).inspect(
            libraryURL: URL(fileURLWithPath: "/tmp/libRuntime.dylib"),
            target: target
        )

        #expect(inspection.architecture == "arm64")
        #expect(inspection.installName == "@rpath/libRuntime.dylib")
        #expect(
            inspection.dynamicDependencies == ["/usr/lib/libSystem.B.dylib"]
        )
        #expect(
            inspection.exportedSymbols == [
                "AsyncRT_DeviceContext_create",
                "KGEN_CompilerRT_AlignedAlloc",
            ]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func parsesLinuxRuntimeMetadata() throws {
        let target = try MojoTargetConfiguration(
            triple: "aarch64-unknown-linux-gnu",
            cpu: "cortex-a78ae",
            accelerator: "sm_87"
        )
        let inspection = try MojoRuntimeBinaryInspector(
            processRunner: FixtureRuntimeMetadataRunner(),
            environment: [
                "SWIFT_MOJO_LLVM_NM": "/tools/llvm-nm",
                "SWIFT_MOJO_LLVM_READELF": "/tools/llvm-readelf",
            ]
        ).inspect(
            libraryURL: URL(fileURLWithPath: "/tmp/libRuntime.so"),
            target: target
        )

        #expect(inspection.architecture == "arm64")
        #expect(inspection.installName == "libRuntime.so")
        #expect(inspection.dynamicDependencies == ["libc.so.6"])
        #expect(
            inspection.exportedSymbols == [
                "AsyncRT_DeviceContext_create",
                "KGEN_CompilerRT_AlignedAlloc",
            ]
        )
    }
}

private struct RuntimeReceiptFixture {
    let root: URL
    let objectURL: URL
    let libraryURLs: [URL]
    let target: MojoTargetConfiguration
    let options: MojoRuntimeReceiptOptions
    let inspections: [String: MojoRuntimeBinaryInspection]

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
            root.appendingPathComponent("libAsyncRT.dylib"),
            root.appendingPathComponent("libGlobals.dylib"),
            root.appendingPathComponent("libKGEN.dylib"),
        ]
        try Data("object".utf8).write(to: objectURL)
        for (index, url) in libraryURLs.enumerated() {
            try Data("runtime-\(index)".utf8).write(to: url)
        }
        target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "apple-gpu"
        )
        options = try MojoRuntimeReceiptOptions(
            objectURL: objectURL,
            libraryURLs: libraryURLs,
            target: target
        )
        inspections = [
            "libAsyncRT.dylib": MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/libAsyncRT.dylib",
                dynamicDependencies: [],
                exportedSymbols: ["AsyncRT_DeviceContext_create"]
            ),
            "libGlobals.dylib": MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/libGlobals.dylib",
                dynamicDependencies: ["/usr/lib/libSystem.B.dylib"],
                exportedSymbols: []
            ),
            "libKGEN.dylib": MojoRuntimeBinaryInspection(
                architecture: "arm64",
                installName: "@rpath/libKGEN.dylib",
                dynamicDependencies: ["@rpath/libGlobals.dylib"],
                exportedSymbols: ["KGEN_CompilerRT_AlignedAlloc"]
            ),
        ]
    }

    func preparer(
        inspections: [String: MojoRuntimeBinaryInspection]? = nil,
        objectArchitecture: String = "arm64"
    ) -> MojoRuntimeReceiptPreparer {
        MojoRuntimeReceiptPreparer(
            binaryInspector: FixtureRuntimeBinaryInspector(
                inspections: inspections ?? self.inspections,
                objectArchitecture: objectArchitecture
            ),
            processRunner: FixtureRuntimeObjectRunner(
                undefinedSymbols: [
                    "_AsyncRT_DeviceContext_create",
                    "_KGEN_CompilerRT_AlignedAlloc",
                    "_memcpy",
                ]
            )
        )
    }

    func inspection(
        installName: String,
        dependencies: [String],
        exports: Set<String>
    ) -> MojoRuntimeBinaryInspection {
        MojoRuntimeBinaryInspection(
            architecture: "arm64",
            installName: installName,
            dynamicDependencies: dependencies,
            exportedSymbols: exports
        )
    }
}

private func withRuntimeFixture(
    _ body: (RuntimeReceiptFixture) throws -> Void
) throws {
    let fixture = try RuntimeReceiptFixture()
    defer {
        do {
            try FileManager.default.removeItem(at: fixture.root)
        } catch {
            Issue.record("Failed to remove runtime receipt fixture: \(error)")
        }
    }
    try body(fixture)
}
