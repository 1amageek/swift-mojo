import Foundation
import MojoArtifactCore
import MojoBindingCore
import MojoCompilerCore
import MojoRuntime
import Testing

@Suite("Public Mojo runtime worker bundle verification")
struct MojoRuntimeWorkerBundleVerifierTests {
    @Test(.timeLimit(.minutes(1)))
    func projectsClosedWorkerMetadataIntoImmutablePublicValues() throws {
        let manifest = try workerManifestFixture()
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("../RuntimeWorker.bundle", isDirectory: true)

        let verification = try FileSystemMojoRuntimeWorkerBundleVerifier
            .verification(from: manifest, bundleURL: bundleURL)

        #expect(verification.schemaVersion == 1)
        #expect(verification.bundleDigest == manifest.digest)
        #expect(
            verification.executionContractDigest
                == manifest.executionContractDigest
        )
        #expect(
            verification.workerABIVersion
                == manifest.semanticIdentity.workerABIVersion
        )
        #expect(
            verification.sourceGraphDigest
                == manifest.semanticIdentity.sourceGraphDigest
        )
        #expect(
            verification.sourceGraphIdentifier
                == manifest.semanticIdentity.sourceGraphIdentifier
        )
        #expect(
            verification.inputGraphDigest
                == manifest.semanticIdentity.inputGraphDigest
        )
        #expect(
            verification.inputGraphIdentifier
                == manifest.semanticIdentity.inputGraphIdentifier
        )
        #expect(
            verification.generationPipelineDigest
                == manifest.semanticIdentity.generationPipelineDigest
        )
        #expect(
            verification.bindingTableDigest
                == (try manifest.semanticIdentity.bindingTable).digest
        )
        #expect(
            verification.bindings == [
                MojoRuntimeWorkerBinding(
                    bindingID: MojoBinding.bindingIdentifier(
                        functionName: "createModelSession",
                        signature: .runtimeSessionFactory
                    ),
                    functionName: "createModelSession",
                    signature: .runtimeSessionFactory,
                    sessionFactoryFunctionName: nil
                ),
                MojoRuntimeWorkerBinding(
                    bindingID: MojoBinding.bindingIdentifier(
                        functionName: "executeModelBatch",
                        signature: .sessionBorrowedMutableFloat32Buffers
                    ),
                    functionName: "executeModelBatch",
                    signature: .sessionBorrowedMutableFloat32Buffers,
                    sessionFactoryFunctionName: "createModelSession"
                ),
            ].sorted { $0.bindingID < $1.bindingID }
        )
        #expect(
            verification.generatedMojoSourceDigest
                == manifest.generatedInputs.generatedMojoSourceDigest
        )
        #expect(
            verification.generatedCWorkerSourceDigest
                == manifest.generatedInputs.generatedCWorkerSourceDigest
        )
        #expect(
            verification.sourceMapDigest
                == manifest.generatedInputs.sourceMapDigest
        )
        #expect(
            verification.generatedMojoObjectDigest
                == manifest.generatedInputs.generatedMojoObjectDigest
        )
        #expect(
            verification.generatedCWorkerObjectDigest
                == manifest.generatedInputs.generatedCWorkerObjectDigest
        )
        #expect(
            verification.target.identity
                == "arm64-apple-macosx14.0|apple-m4|metal"
        )
        #expect(verification.compilerVersion == "Mojo 1.0.0")
        #expect(
            verification.protocolVersion == manifest.protocolRecord.version
        )
        #expect(
            verification.protocolDescriptor
                == manifest.protocolRecord.descriptor
        )
        #expect(
            verification.protocolHeaderByteCount
                == manifest.protocolRecord.headerByteCount
        )
        #expect(
            verification.protocolByteOrder
                == manifest.protocolRecord.byteOrder
        )
        #expect(verification.maximumFramePayloadBytes == 65_536)
        #expect(
            verification.maximumInFlightRequests
                == manifest.protocolRecord.maximumInFlightRequests
        )
        #expect(
            verification.protocolMessageKinds.map {
                "\($0.rawValue):\($0.name)"
            }
                == manifest.protocolRecord.messageKinds.map {
                    "\($0.rawValue):\($0.name)"
                }
        )
        #expect(
            verification.runtimeBundleManifestDigest
                == manifest.runtimeBundle.manifestDigest
        )
        #expect(
            verification.runtimeReceiptDigest
                == manifest.runtimeBundle.receiptDigest
        )
        #expect(
            verification.executable == MojoRuntimeBundleFile(
                relativePath: "bin/manas-worker",
                sha256Digest: String(repeating: "b", count: 64)
            )
        )
        #expect(
            verification.libraries == [
                MojoRuntimeBundleFile(
                    relativePath: "lib/libAsyncRT.dylib",
                    sha256Digest: String(repeating: "c", count: 64)
                ),
            ]
        )
        #expect(
            verification.loaderSearchPath
                == manifest.runtimeBundle.loaderSearchPath
        )
        #expect(
            verification.systemDependencies
                == manifest.runtimeBundle.systemDependencies
        )
        #expect(
            verification.programInterpreter
                == manifest.runtimeBundle.programInterpreter
        )
        #expect(
            verification.artifactIdentity.targetName
                == manifest.targetClosure.artifactIdentity.targetName
        )
        #expect(
            verification.artifactIdentity.moduleName
                == manifest.targetClosure.artifactIdentity.moduleName
        )
        #expect(
            verification.artifactIdentity.artifactName
                == manifest.targetClosure.artifactIdentity.artifactName
        )
        #expect(
            verification.artifactIdentity.libraryName
                == manifest.targetClosure.artifactIdentity.libraryName
        )
        #expect(
            verification.artifactIdentity.symbolPrefix
                == manifest.targetClosure.artifactIdentity.symbolPrefix
        )
        #expect(
            verification.targetClosureDigest
                == manifest.targetClosure.targetClosureDigest
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func missingWorkerBundleIsAPublicTypedFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try FileSystemMojoRuntimeWorkerBundleVerifier()
                .verifyWorkerBundle(at: missing)
            Issue.record("Missing runtime worker bundle unexpectedly verified")
        } catch let error as MojoRuntimeBundleVerificationError {
            guard case .invalidBundle(let detail) = error else {
                Issue.record("Unexpected typed error: \(error)")
                return
            }
            #expect(detail.contains("not a managed swift-mojo output"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verifiesOptInWorkerBundleThroughFreshFilesystemInspection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bundlePath = environment[
            "SWIFT_MOJO_TEST_RUNTIME_WORKER_BUNDLE"
        ] else {
            return
        }
        guard let expectedDigest = environment[
            "SWIFT_MOJO_TEST_RUNTIME_WORKER_BUNDLE_DIGEST"
        ] else {
            Issue.record(
                "SWIFT_MOJO_TEST_RUNTIME_WORKER_BUNDLE_DIGEST is required with the bundle path"
            )
            return
        }

        let verification = try FileSystemMojoRuntimeWorkerBundleVerifier()
            .verifyWorkerBundle(
                at: URL(fileURLWithPath: bundlePath, isDirectory: true)
            )

        #expect(verification.bundleDigest == expectedDigest)
        #expect(verification.schemaVersion == 1)
        #expect(!verification.executionContractDigest.isEmpty)
        #expect(!verification.bindingTableDigest.isEmpty)
        #expect(!verification.bindings.isEmpty)
        #expect(verification.target.accelerator != nil)
        #expect(verification.maximumFramePayloadBytes > 0)
        #expect(!verification.executable.relativePath.isEmpty)
        #expect(!verification.libraries.isEmpty)
    }

#if os(macOS)
    @Test(.timeLimit(.minutes(1)))
    func externalConsumerSeesOnlyTheReadOnlyWorkerProjection() throws {
        try withPublicAPICompiler { compiler in
            let allowed = try compiler.typecheck(
                name: "AllowedWorkerProjection",
                source: """
                import MojoRuntime

                func inspect(
                    _ verification: MojoRuntimeWorkerBundleVerification
                ) {
                    _ = verification.schemaVersion
                    _ = verification.bundleDigest
                    _ = verification.executionContractDigest
                    _ = verification.workerABIVersion
                    _ = verification.sourceGraphDigest
                    _ = verification.sourceGraphIdentifier
                    _ = verification.inputGraphDigest
                    _ = verification.inputGraphIdentifier
                    _ = verification.generationPipelineDigest
                    _ = verification.bindingTableDigest
                    _ = verification.bindings
                    _ = verification.generatedMojoSourceDigest
                    _ = verification.generatedCWorkerSourceDigest
                    _ = verification.sourceMapDigest
                    _ = verification.generatedMojoObjectDigest
                    _ = verification.generatedCWorkerObjectDigest
                    _ = verification.compilerVersion
                    _ = verification.protocolVersion
                    _ = verification.protocolDescriptor
                    _ = verification.protocolHeaderByteCount
                    _ = verification.protocolByteOrder
                    _ = verification.maximumFramePayloadBytes
                    _ = verification.maximumInFlightRequests
                    _ = verification.protocolMessageKinds
                    _ = verification.runtimeBundleManifestDigest
                    _ = verification.runtimeReceiptDigest
                    _ = verification.executable
                    _ = verification.libraries
                    _ = verification.loaderSearchPath
                    _ = verification.systemDependencies
                    _ = verification.programInterpreter
                    _ = verification.target
                    _ = verification.artifactIdentity
                    _ = verification.targetClosureDigest
                }
                """
            )
            #expect(allowed.status == 0, "\(allowed.output)")

            let packagePath = try compiler.typecheck(
                name: "PackageWorkerPath",
                source: """
                import MojoRuntime

                func bundlePath(
                    _ verification: MojoRuntimeWorkerBundleVerification
                ) -> Any {
                    verification.verifiedBundleURL
                }
                """
            )
            #expect(packagePath.status != 0)
            #expect(packagePath.output.contains("verifiedBundleURL"))
            #expect(packagePath.output.contains("inaccessible"))

            let construction = try compiler.typecheck(
                name: "ConstructWorkerProjection",
                source: """
                import Foundation
                import MojoRuntime

                func construct(
                    identity: MojoRuntimeWorkerArtifactIdentity,
                    kinds: [MojoRuntimeWorkerMessageKind],
                    bindings: [MojoRuntimeWorkerBinding],
                    target: MojoRuntimeBundleTarget,
                    executable: MojoRuntimeBundleFile,
                    bundleURL: URL
                ) -> MojoRuntimeWorkerBundleVerification {
                    MojoRuntimeWorkerBundleVerification(
                        schemaVersion: 1,
                        bundleDigest: "digest",
                        executionContractDigest: "contract",
                        workerABIVersion: 1,
                        sourceGraphDigest: "source",
                        sourceGraphIdentifier: 1,
                        inputGraphDigest: "input",
                        inputGraphIdentifier: 1,
                        generationPipelineDigest: "pipeline",
                        bindingTableDigest: "bindings",
                        bindings: bindings,
                        generatedMojoSourceDigest: "mojo-source",
                        generatedCWorkerSourceDigest: "c-source",
                        sourceMapDigest: "source-map",
                        generatedMojoObjectDigest: "mojo-object",
                        generatedCWorkerObjectDigest: "c-object",
                        compilerVersion: "Mojo 1.0.0",
                        protocolVersion: 1,
                        protocolDescriptor: 3,
                        protocolHeaderByteCount: 32,
                        protocolByteOrder: "little-endian",
                        maximumFramePayloadBytes: 4096,
                        maximumInFlightRequests: 1,
                        protocolMessageKinds: kinds,
                        runtimeBundleManifestDigest: "runtime-manifest",
                        runtimeReceiptDigest: "runtime-receipt",
                        executable: executable,
                        libraries: [],
                        loaderSearchPath: "@executable_path/../lib",
                        systemDependencies: [],
                        programInterpreter: nil,
                        target: target,
                        artifactIdentity: identity,
                        targetClosureDigest: "target-closure",
                        verifiedBundleURL: bundleURL
                    )
                }
                """
            )
            #expect(construction.status != 0)
            #expect(
                construction.output.contains("initializer is inaccessible")
            )

            let encoding = try compiler.typecheck(
                name: "EncodeWorkerProjection",
                source: """
                import Foundation
                import MojoRuntime

                func encode(
                    _ verification: MojoRuntimeWorkerBundleVerification
                ) throws -> Data {
                    try JSONEncoder().encode(verification)
                }
                """
            )
            #expect(encoding.status != 0)
            #expect(encoding.output.contains("Encodable"))

            let mutation = try compiler.typecheck(
                name: "MutateWorkerProjection",
                source: """
                import MojoRuntime

                func mutate(
                    _ verification: inout MojoRuntimeWorkerBundleVerification
                ) {
                    verification.schemaVersion = 2
                }
                """
            )
            #expect(mutation.status != 0)
            #expect(mutation.output.contains("schemaVersion"))

            for member in [
                "bundleURL",
                "executableURL",
                "processID",
                "fileDescriptor",
                "rawFrameData",
            ] {
                let forbidden = try compiler.typecheck(
                    name: "Forbidden_\(member)",
                    source: """
                    import MojoRuntime

                    func inspect(
                        _ verification: MojoRuntimeWorkerBundleVerification
                    ) {
                        _ = verification.\(member)
                    }
                    """
                )
                #expect(forbidden.status != 0)
                #expect(forbidden.output.contains(member))
            }
        }
    }
#endif
}

private func workerManifestFixture() throws
    -> MojoRuntimeWorkerBundleManifest
{
    let target = try MojoTargetConfiguration(
        triple: "arm64-apple-macosx14.0",
        cpu: "apple-m4",
        accelerator: "metal"
    )
    let identity = try MojoArtifactIdentity(targetName: "ManasWorker")
    let sourceGraphDigest = String(repeating: "1", count: 64)
    let sourceGraphIdentifier = try #require(
        MojoCanonicalDigest.identifier(fromSHA256Hex: sourceGraphDigest)
    )
    let inputGraphDigest = String(repeating: "2", count: 64)
    let inputGraphIdentifier = try #require(
        MojoCanonicalDigest.identifier(fromSHA256Hex: inputGraphDigest)
    )
    let semanticIdentity = try MojoRuntimeWorkerBundleManifest
        .SemanticIdentity(
            workerABIVersion: MojoRuntimeWorkerRenderer.workerABIVersion,
            protocolVersion: 1,
            sourceGraphDigest: sourceGraphDigest,
            sourceGraphIdentifier: sourceGraphIdentifier,
            inputGraphDigest: inputGraphDigest,
            inputGraphIdentifier: inputGraphIdentifier,
            generationPipelineDigest: String(repeating: "3", count: 64),
            bindings: [
                .init(
                    bindingID: MojoBinding.bindingIdentifier(
                        functionName: "createModelSession",
                        signature: .runtimeSessionFactory
                    ),
                    functionName: "createModelSession",
                    signature: .runtimeSessionFactory,
                    sessionFactoryFunctionName: nil
                ),
                .init(
                    bindingID: MojoBinding.bindingIdentifier(
                        functionName: "executeModelBatch",
                        signature: .sessionBorrowedMutableFloat32Buffers
                    ),
                    functionName: "executeModelBatch",
                    signature: .sessionBorrowedMutableFloat32Buffers,
                    sessionFactoryFunctionName: "createModelSession"
                ),
            ].sorted { $0.bindingID < $1.bindingID }
        )
    let generatedInputs = try MojoRuntimeWorkerBundleManifest.GeneratedInputs(
        generatedMojoSourceDigest: String(repeating: "4", count: 64),
        generatedCWorkerSourceDigest: String(repeating: "5", count: 64),
        sourceMapDigest: String(repeating: "6", count: 64),
        generatedMojoObjectDigest: String(repeating: "7", count: 64),
        generatedCWorkerObjectDigest: String(repeating: "8", count: 64),
        compilerVersion: "Mojo 1.0.0"
    )
    let runtimeBundle = try MojoRuntimeWorkerBundleManifest
        .RuntimeBundleRecord(
            manifestDigest: String(repeating: "9", count: 64),
            receiptDigest: String(repeating: "a", count: 64),
            executable: .init(
                relativePath: "bin/manas-worker",
                digest: String(repeating: "b", count: 64)
            ),
            libraries: [
                try .init(
                    relativePath: "lib/libAsyncRT.dylib",
                    digest: String(repeating: "c", count: 64)
                ),
            ],
            loaderSearchPath: "@executable_path/../lib",
            systemDependencies: ["/usr/lib/libSystem.B.dylib"],
            programInterpreter: nil
        )
    let executionContractDigest = String(repeating: "d", count: 64)
    let targetClosureDigest = try MojoRuntimeWorkerBundleManifest
        .targetClosureDigest(
            semanticIdentity: semanticIdentity,
            generatedInputs: generatedInputs,
            runtimeBundle: runtimeBundle,
            target: target,
            artifactIdentity: identity,
            executionContractDigest: executionContractDigest
        )
    let targetClosure = try MojoRuntimeWorkerBundleManifest.TargetClosure(
        target: target,
        artifactIdentity: identity,
        targetClosureDigest: targetClosureDigest
    )
    return try MojoRuntimeWorkerBundleManifest(
        semanticIdentity: semanticIdentity,
        generatedInputs: generatedInputs,
        protocolRecord: .init(maximumFramePayloadBytes: 65_536),
        runtimeBundle: runtimeBundle,
        targetClosure: targetClosure,
        executionContractDigest: executionContractDigest
    )
}

#if os(macOS)
private struct PublicAPICompiler {
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
        // The pinned Swift 6.4 snapshot can abort once while closing a newly
        // populated Clang module cache. A single identical retry consumes the
        // completed cache and still preserves the compiler's real result.
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

private func withPublicAPICompiler(
    _ body: (PublicAPICompiler) throws -> Void
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
                "MojoRuntime.swiftmodule",
                isDirectory: true
            ).path
          ) {
        moduleSearchPath.deleteLastPathComponent()
    }
    let moduleURL = moduleSearchPath.appendingPathComponent(
        "MojoRuntime.swiftmodule",
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
        Issue.record(
            "MojoRuntime module is missing from the test products"
        )
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
            Issue.record("Failed to remove public API compile fixture: \(error)")
        }
    }
    try body(
        PublicAPICompiler(
            rootURL: rootURL,
            moduleSearchPath: moduleSearchPath,
            mojoPOSIXSupportModuleMap: mojoPOSIXSupportModuleMap,
            swiftSyntaxCShimsIncludePath: swiftSyntaxCShimsIncludePath
        )
    )
}
#endif
