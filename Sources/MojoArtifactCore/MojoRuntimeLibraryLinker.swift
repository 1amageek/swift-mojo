import Foundation
import MojoCompilerCore

package struct MojoRuntimeLibraryLinker: MojoRuntimeLibraryLinking, Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func link(
        objectURL: URL,
        libraryURLs: [URL],
        outputURL: URL,
        target: MojoTargetConfiguration,
        systemDependencies: [String],
        exportedSymbols: Set<String>
    ) throws {
        guard !exportedSymbols.isEmpty,
              exportedSymbols.allSatisfy(
                MojoRuntimeLoaderPolicy.isPortableCSymbol
              ) else {
            throw MojoArtifactError.invalidArguments(
                "Runtime library exports must be nonempty portable C symbols"
            )
        }
        let tool = try clang(target: target)
        let exportListURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".exports-\(UUID().uuidString)")
        let triple = target.triple.lowercased()
        let exportList: String
        var arguments = tool.prefixArguments + [
            "-target", target.triple,
        ]
        if triple.contains("-apple-") {
            exportList = exportedSymbols.sorted()
                .map { "_\($0)" }
                .joined(separator: "\n") + "\n"
            arguments.append(contentsOf: [
                "-dynamiclib",
                "-Wl,-install_name,@rpath/\(outputURL.lastPathComponent)",
                "-Wl,-rpath,@loader_path",
                "-Wl,-exported_symbols_list,\(exportListURL.path)",
            ])
        } else if triple.contains("-linux-") {
            exportList = [
                "{",
                "  global:",
                exportedSymbols.sorted().map { "    \($0);" }
                    .joined(separator: "\n"),
                "  local: *;",
                "};",
                "",
            ].joined(separator: "\n")
            arguments.append(contentsOf: [
                "-shared",
                "-Wl,-soname,\(outputURL.lastPathComponent)",
                "-Wl,-rpath,$ORIGIN",
                "-Wl,--enable-new-dtags",
                "-Wl,--version-script=\(exportListURL.path)",
            ])
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        arguments.append(objectURL.path)
        arguments.append(contentsOf: libraryURLs.map(\.path))
        if triple.contains("-linux-") {
            let explicitSystemLibraries = systemDependencies.filter {
                !MojoRuntimeReceiptPreparer.isDefaultSystemDependency(
                    $0,
                    target: target
                )
            }
            arguments.append(
                contentsOf: explicitSystemLibraries.sorted().map {
                    "-Wl,-l:\($0)"
                }
            )
        }
        arguments.append(contentsOf: ["-o", outputURL.path])
        let result = try withExportList(
            exportList,
            at: exportListURL
        ) {
            try processRunner.capture(
                executablePath: tool.executablePath,
                arguments: arguments
            )
        }
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([tool.executablePath] + arguments).joined(
                    separator: " "
                ),
                status: result.status,
                diagnostic: result.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
    }

    private func withExportList<Result>(
        _ contents: String,
        at url: URL,
        operation: () throws -> Result
    ) throws -> Result {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        do {
            let result = try operation()
            try FileManager.default.removeItem(at: url)
            return result
        } catch {
            let primaryError = error
            do {
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                throw MojoArtifactError.commandFailed(
                    command: "clean runtime library export list",
                    status: -1,
                    diagnostic: "Primary error: \(primaryError); cleanup error: \(error)"
                )
            }
            throw primaryError
        }
    }

    private func clang(
        target: MojoTargetConfiguration
    ) throws -> (executablePath: String, prefixArguments: [String]) {
        if let path = environment["SWIFT_MOJO_CLANG"] {
            guard NSString(string: path).isAbsolutePath else {
                throw MojoArtifactError.invalidArguments(
                    "SWIFT_MOJO_CLANG must be an absolute path"
                )
            }
            return (path, [])
        }
#if os(macOS)
        if target.triple.lowercased().contains("-apple-") {
            return ("/usr/bin/xcrun", ["clang"])
        }
#endif
        return ("/usr/bin/clang", [])
    }

}
