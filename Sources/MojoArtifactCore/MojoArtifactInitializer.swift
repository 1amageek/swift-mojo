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
        outputDirectoryURL: URL,
        identity: MojoArtifactIdentity = .legacy
    ) throws -> MojoInitializationDisposition {
        try transaction.withExclusiveAccess(to: outputDirectoryURL) { access in
            try initialize(
                outputDirectoryURL: outputDirectoryURL,
                identity: identity,
                access: access
            )
        }
    }

    private func initialize(
        outputDirectoryURL: URL,
        identity: MojoArtifactIdentity,
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
                identity.artifactName,
                isDirectory: true
            )
            guard fileManager.fileExists(atPath: artifactURL.path) else {
                throw MojoArtifactError.invalidManagedOutputDirectory(
                    outputDirectoryURL.path
                )
            }
            let archives = try MojoArtifactVerifier.archiveURLs(
                in: artifactURL,
                identity: identity
            )
            let infoPlistURL = artifactURL.appendingPathComponent("Info.plist")
            guard !archives.isEmpty,
                  fileManager.fileExists(atPath: infoPlistURL.path),
                  archives.allSatisfy({ archiveURL in
                    Self.hasCompleteInterface(
                        for: archiveURL,
                        identity: identity,
                        fileManager: fileManager
                    )
                  }) else {
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
            try createBootstrap(in: staging, identity: identity)
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

    private func createBootstrap(
        in staging: URL,
        identity: MojoArtifactIdentity
    ) throws {
        let buildURL = staging.appendingPathComponent(
            ".bootstrap",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: buildURL,
            withIntermediateDirectories: false
        )
        let sourceURL = buildURL.appendingPathComponent("Bootstrap.c")
        let objectURL = buildURL.appendingPathComponent("Bootstrap.o")
        let archiveURL = buildURL.appendingPathComponent(
            identity.libraryName
        )
        let frameworkURL = MojoStaticFrameworkLayout.frameworkURL(
            in: buildURL,
            identity: identity
        )
        let artifactURL = staging.appendingPathComponent(
            identity.artifactName,
            isDirectory: true
        )
        let prefix = identity.symbolPrefix
        let graphFunction = identity == .legacy
            ? "\(prefix)_source_graph_identifier"
            : "\(prefix)_input_graph_identifier"
        // FIXME(INCOMPLETE_IMPLEMENTATION): The init command emits an
        // intentionally invalid bootstrap ABI so SwiftPM can load the local
        // binary-target path. Normal build verification rejects this path
        // because it has no manifest. It must never be treated as prepared
        // until prepare replaces it with a compiler-produced artifact and
        // matching manifest.
        let source = """
        #include <stdint.h>

        uint32_t \(prefix)_static_abi_version(void) { return 0; }
        uint64_t \(graphFunction)(void) { return 0; }
        uint32_t \(prefix)_has_binding(uint64_t binding_id) {
            (void)binding_id;
            return 0;
        }
        int32_t \(prefix)_call_i32_i32_i32(
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
        let header = identity == .legacy
            ? renderer.header
            : renderer.header(identity: identity)
        try run(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "clang",
                "-arch", Self.hostArchitecture,
                "-mmacosx-version-min=14.0",
                "-c", sourceURL.path,
                "-o", objectURL.path,
            ]
        )
        try run(
            executablePath: "/usr/bin/ar",
            arguments: ["rcs", archiveURL.path, objectURL.path]
        )
        try MojoStaticFrameworkLayout.createFramework(
            at: frameworkURL,
            identity: identity,
            archiveURL: archiveURL,
            header: header,
            moduleMap: renderer.frameworkModuleMap(identity: identity)
        )
        try run(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "-create-xcframework",
                "-framework", frameworkURL.path,
                "-output", artifactURL.path,
            ]
        )
        try FileManager.default.removeItem(at: buildURL)
    }

    private static func hasCompleteInterface(
        for archiveURL: URL,
        identity: MojoArtifactIdentity,
        fileManager: FileManager
    ) -> Bool {
        if archiveURL.lastPathComponent == identity.moduleName {
            let frameworkURL = archiveURL.deletingLastPathComponent()
            return fileManager.fileExists(
                atPath: MojoStaticFrameworkLayout.modulesURL(
                    in: frameworkURL
                ).appendingPathComponent("module.modulemap").path
            ) && fileManager.fileExists(
                atPath: MojoStaticFrameworkLayout.headersURL(
                    in: frameworkURL
                ).appendingPathComponent("\(identity.moduleName).h").path
            ) && fileManager.fileExists(
                atPath: frameworkURL.appendingPathComponent("Info.plist").path
            )
        }
        let headersURL = archiveURL.deletingLastPathComponent()
            .appendingPathComponent("Headers", isDirectory: true)
        return fileManager.fileExists(
            atPath: headersURL.appendingPathComponent("module.modulemap").path
        ) && fileManager.fileExists(
            atPath: headersURL.appendingPathComponent(
                "\(identity.moduleName).h"
            ).path
        )
    }

    private static var hostArchitecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unsupported-host"
#endif
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
