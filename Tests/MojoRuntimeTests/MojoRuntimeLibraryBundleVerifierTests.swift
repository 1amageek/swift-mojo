import Foundation
import MojoArtifactCore
import MojoCompilerCore
import MojoRuntime
import Testing

@Suite("Public Mojo runtime library bundle verification")
struct MojoRuntimeLibraryBundleVerifierTests {
    @Test(.timeLimit(.minutes(1)))
    func exposesOnlyVerifiedRuntimeLibraryMetadata() throws {
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "metal:4"
        )
        let manifest = MojoRuntimeLibraryBundleManifest(
            receiptDigest: String(repeating: "a", count: 64),
            target: target,
            moduleName: "SwiftMojo_Model_ABI",
            compilerVersion: "Mojo 1.0.0",
            inputGraphDigest: String(repeating: "f", count: 64),
            inputGraphIdentifier: 42,
            generatedSourceDigest: String(repeating: "1", count: 64),
            sourceMapDigest: String(repeating: "2", count: 64),
            loaderSearchPath: "@loader_path",
            library: .init(
                relativePath: "lib/libSwiftMojo_Model_ABI.dylib",
                digest: String(repeating: "b", count: 64)
            ),
            runtimeLibraries: [
                .init(
                    relativePath: "lib/libAsyncRT.dylib",
                    digest: String(repeating: "c", count: 64)
                ),
            ],
            interfaceHeader: .init(
                relativePath: "include/SwiftMojo_Model_ABI.h",
                digest: String(repeating: "d", count: 64)
            ),
            moduleMap: .init(
                relativePath: "include/module.modulemap",
                digest: String(repeating: "e", count: 64)
            ),
            exportedSymbols: ["swift_mojo_model_create_session_v1"],
            systemDependencies: ["/usr/lib/libSystem.B.dylib"]
        )

        let verification = FileSystemMojoRuntimeLibraryBundleVerifier
            .verification(from: manifest)

        #expect(verification.schemaVersion == 2)
        #expect(verification.bundleDigest == manifest.digest)
        #expect(verification.receiptDigest == manifest.receiptDigest)
        #expect(verification.target.identity == target.identity)
        #expect(verification.moduleName == manifest.moduleName)
        #expect(verification.compilerVersion == "Mojo 1.0.0")
        #expect(verification.inputGraphDigest == String(repeating: "f", count: 64))
        #expect(verification.inputGraphIdentifier == 42)
        #expect(
            verification.generatedSourceDigest
                == String(repeating: "1", count: 64)
        )
        #expect(
            verification.sourceMapDigest
                == String(repeating: "2", count: 64)
        )
        #expect(verification.loaderSearchPath == "@loader_path")
        #expect(verification.library.relativePath == manifest.library.relativePath)
        #expect(
            verification.runtimeLibraries[0].relativePath
                == "lib/libAsyncRT.dylib"
        )
        #expect(
            verification.interfaceHeader.relativePath
                == "include/SwiftMojo_Model_ABI.h"
        )
        #expect(verification.moduleMap.relativePath == "include/module.modulemap")
        #expect(
            verification.exportedSymbols
                == ["swift_mojo_model_create_session_v1"]
        )
        #expect(
            verification.systemDependencies
                == ["/usr/lib/libSystem.B.dylib"]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func missingLibraryBundleIsAPublicTypedFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try FileSystemMojoRuntimeLibraryBundleVerifier()
                .verifyLibraryBundle(at: missing)
            Issue.record("Missing runtime library bundle unexpectedly verified")
        } catch let error as MojoRuntimeBundleVerificationError {
            guard case .invalidBundle(let detail) = error else {
                Issue.record("Unexpected typed error: \(error)")
                return
            }
            #expect(detail.contains("not a managed swift-mojo output"))
        }
    }
}
