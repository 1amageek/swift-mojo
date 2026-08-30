import Foundation
import MojoCompilerCore
import MojoRuntime
import MojoRuntimeWorker
import Testing

@Suite("Mojo runtime worker public construction authority")
struct MojoRuntimeWorkerPublicSurfaceTests {
    @Test(.timeLimit(.minutes(1)))
    func issuesOpaqueTokensOnlyForExactVerifiedBindings() throws {
        let bindings = validBindings()
        let verification = verification(
            bundleDigest: digest("a"),
            bindings: bindings
        )
        let worker = try MojoRuntimeWorker(verification: verification)

        let factory = try worker.sessionFactory(for: bindings[0])
        let standalone = try worker.float32Operation(for: bindings[1])
        let sessionOperation = try worker.float32Operation(for: bindings[2])

        #expect(try worker.validatedBinding(for: factory) == bindings[0])
        #expect(try worker.validatedBinding(for: standalone) == bindings[1])
        #expect(
            try worker.validatedBinding(for: sessionOperation) == bindings[2]
        )

        let alteredRecord = MojoRuntimeWorkerBinding(
            bindingID: bindings[0].bindingID,
            functionName: "differentFactory",
            signature: bindings[0].signature,
            sessionFactoryFunctionName: bindings[0]
                .sessionFactoryFunctionName
        )
        #expect(throws: MojoRuntimeWorkerError.bindingNotInVerification) {
            try worker.sessionFactory(for: alteredRecord)
        }

        let forgedFactory = MojoRuntimeWorkerSessionFactory(
            bundleDigest: verification.bundleDigest,
            binding: bindings[1]
        )
        #expect(
            throws: MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [.runtimeSessionFactory],
                actual: .borrowedFloat32Buffer
            )
        ) {
            try worker.validatedBinding(for: forgedFactory)
        }

        let forgedOperation = MojoRuntimeWorkerFloat32Operation(
            bundleDigest: verification.bundleDigest,
            binding: bindings[0]
        )
        #expect(
            throws: MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [
                    .borrowedFloat32Buffer,
                    .borrowedMutableFloat32Buffers,
                    .sessionBorrowedMutableFloat32Buffers,
                ],
                actual: .runtimeSessionFactory
            )
        ) {
            try worker.validatedBinding(for: forgedOperation)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func tokenCannotCrossAWorkerProjectionBoundary() throws {
        let bindings = validBindings()
        let first = try MojoRuntimeWorker(
            verification: verification(
                bundleDigest: digest("a"),
                bindings: bindings
            )
        )
        let second = try MojoRuntimeWorker(
            verification: verification(
                bundleDigest: digest("b"),
                bindings: bindings
            )
        )

        let factory = try first.sessionFactory(for: bindings[0])
        let operation = try first.float32Operation(for: bindings[2])

        #expect(throws: MojoRuntimeWorkerError.workerProjectionMismatch) {
            try second.validatedBinding(for: factory)
        }
        #expect(throws: MojoRuntimeWorkerError.workerProjectionMismatch) {
            try second.validatedBinding(for: operation)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func distinguishesFactoryAndFloat32BindingSignatures() throws {
        let bindings = validBindings()
        let worker = try MojoRuntimeWorker(
            verification: verification(
                bundleDigest: digest("a"),
                bindings: bindings
            )
        )

        #expect(
            throws: MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [.runtimeSessionFactory],
                actual: .borrowedFloat32Buffer
            )
        ) {
            try worker.sessionFactory(for: bindings[1])
        }
        #expect(
            throws: MojoRuntimeWorkerError.unsupportedBindingSignature(
                expected: [
                    .borrowedFloat32Buffer,
                    .borrowedMutableFloat32Buffers,
                    .sessionBorrowedMutableFloat32Buffers,
                ],
                actual: .runtimeSessionFactory
            )
        ) {
            try worker.float32Operation(for: bindings[0])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func enforcesSessionRelationshipsBySignature() throws {
        let factory = validBindings()[0]
        let standaloneWithRelationship = MojoRuntimeWorkerBinding(
            bindingID: 10,
            functionName: "standaloneWithRelationship",
            signature: .borrowedMutableFloat32Buffers,
            sessionFactoryFunctionName: factory.functionName
        )
        let sessionWithoutRelationship = MojoRuntimeWorkerBinding(
            bindingID: 11,
            functionName: "sessionWithoutRelationship",
            signature: .sessionBorrowedMutableFloat32Buffers,
            sessionFactoryFunctionName: nil
        )
        let sessionWithMissingFactory = MojoRuntimeWorkerBinding(
            bindingID: 12,
            functionName: "sessionWithMissingFactory",
            signature: .sessionBorrowedMutableFloat32Buffers,
            sessionFactoryFunctionName: "missingFactory"
        )

        let malformedBindings = [
            factory,
            standaloneWithRelationship,
            sessionWithoutRelationship,
            sessionWithMissingFactory,
        ]
        let worker = try MojoRuntimeWorker(
            verification: verification(
                bundleDigest: digest("a"),
                bindings: malformedBindings
            )
        )

        #expect(
            throws: MojoRuntimeWorkerError
                .unexpectedSessionFactoryRelationship
        ) {
            try worker.float32Operation(for: standaloneWithRelationship)
        }
        #expect(
            throws: MojoRuntimeWorkerError.missingSessionFactoryRelationship
        ) {
            try worker.float32Operation(for: sessionWithoutRelationship)
        }
        #expect(
            throws: MojoRuntimeWorkerError
                .unresolvedSessionFactoryRelationship
        ) {
            try worker.float32Operation(for: sessionWithMissingFactory)
        }
    }

#if os(macOS)
    @Test(.timeLimit(.minutes(1)))
    func externalConsumerSeesOnlyTypedConstructionAuthority() throws {
        try withWorkerPublicAPICompiler { compiler in
            let allowed = try compiler.typecheck(
                name: "AllowedWorkerConstruction",
                source: """
                import MojoRuntime
                import MojoRuntimeWorker

                func select(
                    verification: MojoRuntimeWorkerBundleVerification,
                    factoryBinding: MojoRuntimeWorkerBinding,
                    operationBinding: MojoRuntimeWorkerBinding
                ) throws {
                    let worker = try MojoRuntimeWorker(
                        verification: verification
                    )
                    _ = try worker.sessionFactory(for: factoryBinding)
                    _ = try worker.float32Operation(for: operationBinding)
                }
                """
            )
            #expect(allowed.status == 0, Comment(rawValue: allowed.output))

            let tokenForgery = try compiler.typecheck(
                name: "ForbiddenWorkerTokenForgery",
                source: """
                import MojoRuntime
                import MojoRuntimeWorker

                func forge(binding: MojoRuntimeWorkerBinding) {
                    _ = MojoRuntimeWorkerSessionFactory(
                        bundleDigest: "untrusted",
                        binding: binding
                    )
                    _ = MojoRuntimeWorkerFloat32Operation(
                        bundleDigest: "untrusted",
                        binding: binding
                    )
                }
                """
            )
            #expect(tokenForgery.status != 0)
            #expect(tokenForgery.output.contains("inaccessible"))

            let rawSurface = try compiler.typecheck(
                name: "ForbiddenWorkerRawSurface",
                source: """
                import Foundation
                import MojoRuntimeWorker

                func inspect(
                    worker: MojoRuntimeWorker,
                    factory: MojoRuntimeWorkerSessionFactory,
                    operation: MojoRuntimeWorkerFloat32Operation
                ) throws {
                    _ = worker.verification
                    _ = worker.verifiedBundleURL
                    _ = worker.executable
                    _ = worker.transport
                    _ = worker.pid
                    _ = worker.fileDescriptor
                    _ = factory.bindingID
                    _ = operation.bindingID
                    _ = MojoRuntimeFrame()
                    _ = try MojoRuntimeWorker(
                        executableURL: URL(fileURLWithPath: "/tmp/worker")
                    )
                }
                """
            )
            #expect(rawSurface.status != 0)
            for forbiddenName in [
                "verification",
                "verifiedBundleURL",
                "executable",
                "transport",
                "pid",
                "fileDescriptor",
                "bindingID",
                "MojoRuntimeFrame",
                "executableURL",
            ] {
                #expect(
                    rawSurface.output.contains(forbiddenName),
                    "Missing compiler rejection for \(forbiddenName)"
                )
            }
        }
    }
#endif
}

private func validBindings() -> [MojoRuntimeWorkerBinding] {
    let factory = MojoRuntimeWorkerBinding(
        bindingID: 1,
        functionName: "createSession",
        signature: .runtimeSessionFactory,
        sessionFactoryFunctionName: nil
    )
    return [
        factory,
        MojoRuntimeWorkerBinding(
            bindingID: 2,
            functionName: "standaloneFloat32",
            signature: .borrowedFloat32Buffer,
            sessionFactoryFunctionName: nil
        ),
        MojoRuntimeWorkerBinding(
            bindingID: 3,
            functionName: "sessionFloat32",
            signature: .sessionBorrowedMutableFloat32Buffers,
            sessionFactoryFunctionName: factory.functionName
        ),
    ]
}

private func verification(
    bundleDigest: String,
    bindings: [MojoRuntimeWorkerBinding]
) -> MojoRuntimeWorkerBundleVerification {
    MojoRuntimeWorkerBundleVerification(
        schemaVersion: 1,
        bundleDigest: bundleDigest,
        executionContractDigest: digest("c"),
        workerABIVersion: 1,
        sourceGraphDigest: digest("d"),
        sourceGraphIdentifier: 1,
        inputGraphDigest: digest("e"),
        inputGraphIdentifier: 2,
        generationPipelineDigest: digest("f"),
        bindingTableDigest: digest("0"),
        bindings: bindings,
        generatedMojoSourceDigest: digest("1"),
        generatedCWorkerSourceDigest: digest("2"),
        sourceMapDigest: digest("3"),
        generatedMojoObjectDigest: digest("4"),
        generatedCWorkerObjectDigest: digest("5"),
        compilerVersion: "Mojo 1.0.0",
        protocolVersion: 1,
        protocolDescriptor: 3,
        protocolHeaderByteCount: 32,
        protocolByteOrder: "littleEndian",
        maximumFramePayloadBytes: 65_536,
        maximumInFlightRequests: 1,
        protocolMessageKinds: [],
        runtimeBundleManifestDigest: digest("6"),
        runtimeReceiptDigest: digest("7"),
        executable: MojoRuntimeBundleFile(
            relativePath: "bin/worker",
            sha256Digest: digest("8")
        ),
        libraries: [],
        loaderSearchPath: "@executable_path/../lib",
        systemDependencies: [],
        programInterpreter: nil,
        target: MojoRuntimeBundleTarget(
            triple: "arm64-apple-macosx",
            cpu: "apple-m4",
            accelerator: "metal"
        ),
        artifactIdentity: MojoRuntimeWorkerArtifactIdentity(
            targetName: "Worker",
            moduleName: "Worker",
            artifactName: "Worker",
            libraryName: "Worker",
            symbolPrefix: "worker"
        ),
        targetClosureDigest: digest("9"),
        verifiedBundleURL: URL(fileURLWithPath: "/verified/worker.bundle")
    )
}

private func digest(_ character: Character) -> String {
    String(repeating: character, count: 64)
}

#if os(macOS)
private struct WorkerPublicAPICompiler {
    let rootURL: URL
    let moduleSearchPath: URL
    let mojoPOSIXSupportModuleMap: URL
    let swiftSyntaxCShimsIncludePath: URL

    func typecheck(
        name: String,
        source: String
    ) throws -> MojoProcessResult {
        let sourceURL = rootURL.appendingPathComponent("\(name).swift")
        try Data(source.utf8).write(to: sourceURL)
        let runner = FoundationMojoProcessRunner(timeoutSeconds: 30)
        let swiftSyntaxModuleMap = swiftSyntaxCShimsIncludePath
            .appendingPathComponent("module.modulemap")
        let arguments = [
            "swiftc",
            "-typecheck",
            "-I", moduleSearchPath.path,
            "-module-cache-path",
            rootURL.appendingPathComponent(
                "ModuleCache",
                isDirectory: true
            ).path,
            "-Xcc",
            "-fmodule-map-file=\(mojoPOSIXSupportModuleMap.path)",
            "-Xcc",
            "-fmodule-map-file=\(swiftSyntaxModuleMap.path)",
            "-Xcc", "-I\(swiftSyntaxCShimsIncludePath.path)",
            sourceURL.path,
        ]
        let result = try runner.capture(
            executablePath: "/usr/bin/xcrun",
            arguments: arguments
        )
        guard result.status == 134,
              result.output.contains("raw_ostream.cpp") else {
            return result
        }
        return try runner.capture(
            executablePath: "/usr/bin/xcrun",
            arguments: arguments
        )
    }
}

private func withWorkerPublicAPICompiler(
    _ body: (WorkerPublicAPICompiler) throws -> Void
) throws {
    let arguments = CommandLine.arguments
    guard let bundlePathIndex = arguments.firstIndex(
        of: "--test-bundle-path"
    ), arguments.indices.contains(bundlePathIndex + 1) else {
        Issue.record("SwiftPM did not provide the test bundle path")
        return
    }
    let executableURL = URL(fileURLWithPath: arguments[bundlePathIndex + 1])
    var moduleSearchPath = executableURL.deletingLastPathComponent()
    while moduleSearchPath.path != "/",
          !FileManager.default.fileExists(
            atPath: moduleSearchPath.appendingPathComponent(
                "MojoRuntimeWorker.swiftmodule",
                isDirectory: true
            ).path
          ) {
        moduleSearchPath.deleteLastPathComponent()
    }
    let moduleURL = moduleSearchPath.appendingPathComponent(
        "MojoRuntimeWorker.swiftmodule",
        isDirectory: true
    )
    let buildRoot = moduleSearchPath
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let scratchRoot = buildRoot.deletingLastPathComponent()
    let mojoPOSIXSupportModuleMap = buildRoot
        .appendingPathComponent("Intermediates.noindex", isDirectory: true)
        .appendingPathComponent("swift-mojo.build", isDirectory: true)
        .appendingPathComponent("Debug", isDirectory: true)
        .appendingPathComponent(
            "CMojoPOSIXSupport-t.build",
            isDirectory: true
        )
        .appendingPathComponent("CMojoPOSIXSupport.modulemap")
    let swiftSyntaxCShimsIncludePath = scratchRoot
        .appendingPathComponent(
            "checkouts/swift-syntax/Sources/_SwiftSyntaxCShims/include",
            isDirectory: true
        )
    guard FileManager.default.fileExists(atPath: moduleURL.path) else {
        Issue.record("MojoRuntimeWorker module is missing from test products")
        return
    }
    guard FileManager.default.fileExists(
        atPath: swiftSyntaxCShimsIncludePath
            .appendingPathComponent("module.modulemap").path
    ) else {
        Issue.record("SwiftSyntax C shim module map is missing")
        return
    }
    guard FileManager.default.fileExists(
        atPath: mojoPOSIXSupportModuleMap.path
    ) else {
        Issue.record("CMojoPOSIXSupport module map is missing")
        return
    }
    let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString,
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: rootURL,
        withIntermediateDirectories: false
    )
    defer {
        do {
            try FileManager.default.removeItem(at: rootURL)
        } catch {
            Issue.record(
                "Failed to remove worker public API compile fixture: \(error)"
            )
        }
    }
    try body(
        WorkerPublicAPICompiler(
            rootURL: rootURL,
            moduleSearchPath: moduleSearchPath,
            mojoPOSIXSupportModuleMap: mojoPOSIXSupportModuleMap,
            swiftSyntaxCShimsIncludePath: swiftSyntaxCShimsIncludePath
        )
    )
}
#endif
