import Foundation
import MojoArtifactCore
import MojoCompilerCore
import MojoRuntime
import Testing

@Suite("Public Mojo runtime bundle verification")
struct MojoRuntimeBundleVerifierTests {
    @Test(.timeLimit(.minutes(1)))
    func exposesVerifiedManifestWithoutSourcePaths() throws {
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "apple-gpu"
        )
        let manifest = MojoRuntimeBundleManifest(
            receiptDigest: String(repeating: "a", count: 64),
            target: target,
            loaderSearchPath: "@executable_path/../lib",
            programInterpreter: nil,
            executable: MojoRuntimeBundleManifest.File(
                relativePath: "bin/kuyu-mojo-worker",
                digest: String(repeating: "b", count: 64)
            ),
            libraries: [
                MojoRuntimeBundleManifest.File(
                    relativePath: "lib/libRuntime.dylib",
                    digest: String(repeating: "c", count: 64)
                ),
            ],
            systemDependencies: ["/usr/lib/libSystem.B.dylib"]
        )

        let verification = FileSystemMojoRuntimeBundleVerifier.verification(
            from: manifest
        )

        #expect(verification.schemaVersion == 1)
        #expect(verification.bundleDigest == manifest.digest)
        #expect(verification.receiptDigest == manifest.receiptDigest)
        #expect(verification.target.identity == target.identity)
        #expect(verification.executable.relativePath == "bin/kuyu-mojo-worker")
        #expect(
            verification.executable.sha256Digest
                == String(repeating: "b", count: 64)
        )
        #expect(
            verification.libraries == [
                MojoRuntimeBundleFile(
                    relativePath: "lib/libRuntime.dylib",
                    sha256Digest: String(repeating: "c", count: 64)
                ),
            ]
        )
        #expect(verification.loaderSearchPath == "@executable_path/../lib")
        #expect(verification.programInterpreter == nil)
        #expect(
            verification.systemDependencies == ["/usr/lib/libSystem.B.dylib"]
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func missingBundleIsAPublicTypedFailure() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        do {
            _ = try FileSystemMojoRuntimeBundleVerifier().verifyBundle(
                at: missing
            )
            Issue.record("Missing bundle unexpectedly verified")
        } catch let error as MojoRuntimeBundleVerificationError {
            guard case .invalidBundle(let detail) = error else {
                Issue.record("Unexpected typed error: \(error)")
                return
            }
            #expect(detail.contains("not a managed swift-mojo output"))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func verifiesOptInDeploymentBundleThroughPublicAPI() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bundlePath = environment[
            "SWIFT_MOJO_TEST_RUNTIME_BUNDLE"
        ] else {
            return
        }
        guard let expectedDigest = environment[
            "SWIFT_MOJO_TEST_RUNTIME_BUNDLE_DIGEST"
        ] else {
            Issue.record(
                "SWIFT_MOJO_TEST_RUNTIME_BUNDLE_DIGEST is required with the bundle path"
            )
            return
        }

        let verification = try FileSystemMojoRuntimeBundleVerifier()
            .verifyBundle(
                at: URL(fileURLWithPath: bundlePath, isDirectory: true)
            )

        #expect(verification.bundleDigest == expectedDigest)
        #expect(!verification.executable.relativePath.isEmpty)
        #expect(!verification.libraries.isEmpty)
    }
}
