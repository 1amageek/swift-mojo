import Foundation
import MojoCompilerCore

package struct MojoArtifactInitializer: Sendable {
    private let processRunner: any MojoProcessRunning
    private let renderer: MojoStaticSourceRenderer
    private let transaction: MojoOutputTransaction

    package init(
        processRunner: any MojoProcessRunning = FoundationMojoProcessRunner(),
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer(),
        transaction: MojoOutputTransaction = MojoOutputTransaction()
    ) {
        self.processRunner = processRunner
        self.renderer = renderer
        self.transaction = transaction
    }

    @discardableResult
    package func initialize(
        outputDirectoryURL: URL
    ) throws -> MojoInitializationDisposition {
        try transaction.withExclusiveAccess(to: outputDirectoryURL) { access in
            try initialize(outputDirectoryURL: outputDirectoryURL, access: access)
        }
    }

    private func initialize(
        outputDirectoryURL: URL,
        access: MojoOutputTransaction.ExclusiveAccess
    ) throws -> MojoInitializationDisposition {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputDirectoryURL.path) {
            guard transaction.isManaged(outputDirectoryURL) else {
                throw MojoArtifactError.unmanagedOutputDirectory(
                    outputDirectoryURL.path
                )
            }
            let artifactURL = outputDirectoryURL.appendingPathComponent(
                MojoStaticABI.artifactName,
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw MojoArtifactError.invalidManagedOutputDirectory(
                    outputDirectoryURL.path
                )
            }
            return .alreadyInitialized
        }
        let staging = try transaction.makeStagingDirectory(
            for: outputDirectoryURL
        )
        do {
            try createBootstrap(in: staging)
            try transaction.commit(
                stagingURL: staging,
                outputURL: outputDirectoryURL,
                access: access
            )
        } catch {
            do {
                if FileManager.default.fileExists(atPath: staging.path) {
                    try FileManager.default.removeItem(at: staging)
                }
            } catch let cleanupError {
                throw MojoArtifactError.commandFailed(
                    command: "clean bootstrap staging directory",
                    status: -1,
                    diagnostic: "Primary error: \(error); cleanup error: \(cleanupError)"
                )
            }
            throw error
        }
        return .initialized
    }

    private func createBootstrap(in staging: URL) throws {
        let sourceURL = staging.appendingPathComponent("Bootstrap.c")
        let objectURL = staging.appendingPathComponent("Bootstrap.o")
        let archiveURL = staging.appendingPathComponent(
            MojoStaticABI.libraryName
        )
        let headersURL = staging.appendingPathComponent(
            "include",
            isDirectory: true
        )
        let artifactURL = staging.appendingPathComponent(
            MojoStaticABI.artifactName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: headersURL,
            withIntermediateDirectories: true
        )
        let source = """
        #include <stdint.h>

        uint32_t swift_mojo_static_abi_version(void) { return 0; }
        uint64_t swift_mojo_source_graph_identifier(void) { return 0; }
        uint32_t swift_mojo_has_binding(uint64_t binding_id) {
            (void)binding_id;
            return 0;
        }
        int32_t swift_mojo_call_i32_i32_i32(
            uint64_t binding_id,
            int32_t lhs,
            int32_t rhs
        ) {
            (void)binding_id;
            (void)lhs;
            (void)rhs;
            __builtin_trap();
        }
        """ + "\n"
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        try renderer.header.write(
            to: headersURL.appendingPathComponent("GeneratedMojoABI.h"),
            atomically: true,
            encoding: .utf8
        )
        try renderer.moduleMap.write(
            to: headersURL.appendingPathComponent("module.modulemap"),
            atomically: true,
            encoding: .utf8
        )
        try run(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "clang",
                "-arch", "arm64",
                "-mmacosx-version-min=14.0",
                "-c", sourceURL.path,
                "-o", objectURL.path,
            ]
        )
        try run(
            executablePath: "/usr/bin/ar",
            arguments: ["rcs", archiveURL.path, objectURL.path]
        )
        try run(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "-create-xcframework",
                "-library", archiveURL.path,
                "-headers", headersURL.path,
                "-output", artifactURL.path,
            ]
        )
        try FileManager.default.removeItem(at: objectURL)
    }

    private func run(
        executablePath: String,
        arguments: [String]
    ) throws {
        let result = try processRunner.capture(
            executablePath: executablePath,
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: result.status,
                diagnostic: result.output
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}
