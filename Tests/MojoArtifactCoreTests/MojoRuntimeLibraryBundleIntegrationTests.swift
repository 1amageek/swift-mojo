import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Mojo runtime library bundle integration")
struct MojoRuntimeLibraryBundleIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func linksVerifiesRelocatesAndInvokesExactRuntimeClosure() throws {
        try withTemporaryDirectory { root in
            let target = try MojoTargetConfiguration(
                triple: "arm64-apple-macosx14.0",
                cpu: "generic",
                accelerator: "test-accelerator:4"
            )
            let identity = try MojoArtifactIdentity(
                targetName: "RuntimeLibraryFixture"
            )
            let input = root.appendingPathComponent("input", isDirectory: true)
            try FileManager.default.createDirectory(
                at: input,
                withIntermediateDirectories: false
            )
            let objectURL = input.appendingPathComponent("Bindings.o")
            let runtimeLibraryURL = input.appendingPathComponent(
                "libFixtureRuntime.dylib"
            )
            try compileInputs(
                inputDirectory: input,
                objectURL: objectURL,
                runtimeLibraryURL: runtimeLibraryURL,
                target: target
            )

            let receiptOptions = try MojoRuntimeReceiptOptions(
                objectURL: objectURL,
                libraryURLs: [runtimeLibraryURL],
                target: target
            )
            let receipt = try MojoRuntimeReceiptPreparer().prepare(
                options: receiptOptions
            )
            let bundleURL = root.appendingPathComponent(
                "RuntimeLibrary.bundle",
                isDirectory: true
            )
            let options = try MojoRuntimeLibraryBundleOptions(
                outputDirectoryURL: bundleURL,
                identity: identity,
                compilerVersion: "Fixture Mojo 1.0",
                inputGraphDigest: String(repeating: "a", count: 64),
                inputGraphIdentifier: 42,
                generatedSourceDigest: String(repeating: "b", count: 64),
                sourceMapDigest: String(repeating: "c", count: 64),
                bindings: [
                    .init(
                        bindingID: 41,
                        functionName: "fixtureCall",
                        signature: "int32Binary"
                    ),
                ],
                exportedSymbols: ["swift_mojo_fixture_call"],
                header: header(moduleName: identity.moduleName),
                moduleMap: moduleMap(moduleName: identity.moduleName),
                objectURL: objectURL,
                libraryURLs: [runtimeLibraryURL],
                target: target
            )
            let manifest = try MojoRuntimeLibraryBundleBuilder().prepare(
                receipt: receipt,
                options: options
            )

            #expect(manifest.target == target)
            #expect(manifest.exportedSymbols == ["swift_mojo_fixture_call"])
            #expect(manifest.bindings.map(\.bindingID) == [41])
            #expect(manifest.loaderSearchPath == "@loader_path")
            #expect(manifest.runtimeLibraries.count == 1)
            #expect(
                manifest.library.relativePath
                    == "lib/\(options.primaryLibraryName)"
            )

            let relocatedURL = root.appendingPathComponent(
                "RelocatedRuntimeLibrary.bundle",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: bundleURL,
                to: relocatedURL
            )
            let relocated = try MojoRuntimeLibraryBundleVerifier().verify(
                bundleURL: relocatedURL
            )
            #expect(relocated == manifest)

            let runnerURL = try compileRunner(in: root)
            let primaryURL = relocatedURL.appendingPathComponent(
                manifest.library.relativePath
            )
            let invocation = try FoundationMojoProcessRunner(
                environment: [:],
                timeoutSeconds: 30
            ).capture(
                executablePath: runnerURL.path,
                arguments: [primaryURL.path]
            )
            #expect(invocation.status == 0)
            #expect(invocation.output == "42\n")

            try expectChangedFileIsRejected(
                sourceBundleURL: bundleURL,
                root: root,
                relativePath: manifest.library.relativePath,
                mutationName: "primary-library"
            )
            try expectChangedFileIsRejected(
                sourceBundleURL: bundleURL,
                root: root,
                relativePath: manifest.runtimeLibraries[0].relativePath,
                mutationName: "runtime-library"
            )
            try expectChangedFileIsRejected(
                sourceBundleURL: bundleURL,
                root: root,
                relativePath: manifest.interfaceHeader.relativePath,
                mutationName: "interface-header"
            )
            let unexpectedEntryBundleURL = root.appendingPathComponent(
                "UnexpectedEntry.bundle",
                isDirectory: true
            )
            try FileManager.default.copyItem(
                at: bundleURL,
                to: unexpectedEntryBundleURL
            )
            try Data("unexpected".utf8).write(
                to: unexpectedEntryBundleURL.appendingPathComponent(
                    "undeclared-file"
                )
            )
            #expect(throws: MojoArtifactError.self) {
                _ = try MojoRuntimeLibraryBundleVerifier().verify(
                    bundleURL: unexpectedEntryBundleURL
                )
            }
        }
    }

    private func expectChangedFileIsRejected(
        sourceBundleURL: URL,
        root: URL,
        relativePath: String,
        mutationName: String
    ) throws {
        let changedBundleURL = root.appendingPathComponent(
            "Changed-\(mutationName).bundle",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: sourceBundleURL,
            to: changedBundleURL
        )
        let changedFileURL = changedBundleURL.appendingPathComponent(
            relativePath
        )
        var contents = try Data(contentsOf: changedFileURL)
        contents.append(contentsOf: [0])
        try contents.write(to: changedFileURL, options: .atomic)
        #expect(throws: MojoArtifactError.self) {
            _ = try MojoRuntimeLibraryBundleVerifier().verify(
                bundleURL: changedBundleURL
            )
        }
    }

    private func compileInputs(
        inputDirectory: URL,
        objectURL: URL,
        runtimeLibraryURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        let runtimeSourceURL = inputDirectory.appendingPathComponent(
            "runtime.c"
        )
        try """
        int AsyncRT_fixture_runtime(int value) {
            return value + 1;
        }
        """.write(
            to: runtimeSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try runClang([
            "-target", target.triple,
            "-dynamiclib", runtimeSourceURL.path,
            "-Wl,-install_name,@rpath/\(runtimeLibraryURL.lastPathComponent)",
            "-o", runtimeLibraryURL.path,
        ])

        let bindingSourceURL = inputDirectory.appendingPathComponent(
            "binding.c"
        )
        try """
        extern int AsyncRT_fixture_runtime(int value);

        int swift_mojo_fixture_call(int value) {
            return AsyncRT_fixture_runtime(value);
        }
        """.write(
            to: bindingSourceURL,
            atomically: true,
            encoding: .utf8
        )
        try runClang([
            "-target", target.triple,
            "-c", bindingSourceURL.path,
            "-o", objectURL.path,
        ])
    }

    private func compileRunner(in root: URL) throws -> URL {
        let sourceURL = root.appendingPathComponent("runner.c")
        let executableURL = root.appendingPathComponent("runtime-runner")
        try """
        #include <dlfcn.h>
        #include <stdio.h>

        typedef int (*fixture_call)(int);

        int main(int argc, char **argv) {
            if (argc != 2) {
                return 10;
            }
            void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
            if (library == NULL) {
                return 11;
            }
            fixture_call call = (fixture_call)dlsym(
                library,
                "swift_mojo_fixture_call"
            );
            if (call == NULL) {
                dlclose(library);
                return 12;
            }
            int value = call(41);
            if (dlclose(library) != 0) {
                return 13;
            }
            printf("%d\\n", value);
            return value == 42 ? 0 : 14;
        }
        """.write(
            to: sourceURL,
            atomically: true,
            encoding: .utf8
        )
        try runClang([
            "-target", "arm64-apple-macosx14.0",
            sourceURL.path,
            "-o", executableURL.path,
        ])
        return executableURL
    }

    private func runClang(_ arguments: [String]) throws {
        let result = try FoundationMojoProcessRunner(
            timeoutSeconds: 30
        ).capture(
            executablePath: "/usr/bin/xcrun",
            arguments: ["clang"] + arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: (["xcrun", "clang"] + arguments).joined(
                    separator: " "
                ),
                status: result.status,
                diagnostic: result.output
            )
        }
    }

    private func header(moduleName: String) -> String {
        """
        #ifndef \(moduleName)_H
        #define \(moduleName)_H

        #include <stdint.h>

        int32_t swift_mojo_fixture_call(int32_t value);

        #endif
        """
    }

    private func moduleMap(moduleName: String) -> String {
        """
        module \(moduleName) {
            header "\(moduleName).h"
            export *
        }
        """
    }

    private func withTemporaryDirectory<Result>(
        operation: (URL) throws -> Result
    ) throws -> Result {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "swift-mojo-runtime-library-test-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        do {
            let result = try operation(root)
            try FileManager.default.removeItem(at: root)
            return result
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: root.path) {
                    try FileManager.default.removeItem(at: root)
                }
            } catch {
                throw MojoArtifactError.commandFailed(
                    command: "clean runtime library integration fixture",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(error)"
                )
            }
            throw primaryError
        }
    }
}
