import Foundation
import MojoCompilerCore

package struct MojoRuntimeBinaryInspector: MojoRuntimeBinaryInspecting, Sendable {
    private let environment: [String: String]
    private let processRunner: any MojoProcessRunning

    package init(
        processRunner: any MojoProcessRunning,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        self.processRunner = processRunner
    }

    package func inspect(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        if target.triple.lowercased().contains("-apple-") {
            return try inspectApple(libraryURL: libraryURL, target: target)
        }
        if target.triple.lowercased().contains("-linux-") {
            return try inspectLinux(libraryURL: libraryURL, target: target)
        }
        throw MojoArtifactError.unsupportedTarget(target.triple)
    }

    package func validateObject(
        objectURL: URL,
        target: MojoTargetConfiguration
    ) throws {
        let expectedArchitecture = try Self.expectedArchitecture(target: target)
        let actual: String
        if target.triple.lowercased().contains("-apple-") {
            let architectures = try appleArchitectures(binaryURL: objectURL)
            guard architectures.contains(expectedArchitecture) else {
                throw MojoArtifactError.runtimeObjectArchitectureMismatch(
                    expected: expectedArchitecture,
                    actual: architectures.joined(separator: ", ")
                )
            }
            return
        } else if target.triple.lowercased().contains("-linux-") {
            let metadata = try linuxMetadata(binaryURL: objectURL)
            actual = Self.elfMachine(from: metadata) ?? "missing"
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        guard Self.elfMachine(actual, matches: expectedArchitecture) else {
            throw MojoArtifactError.runtimeObjectArchitectureMismatch(
                expected: expectedArchitecture,
                actual: actual
            )
        }
    }

    private func inspectApple(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        let architectures = try appleArchitectures(binaryURL: libraryURL)
        let expectedArchitecture = try Self.expectedArchitecture(target: target)
        guard architectures.contains(expectedArchitecture) else {
            throw MojoArtifactError.runtimeLibraryArchitectureMismatch(
                library: libraryURL.lastPathComponent,
                expected: expectedArchitecture,
                actual: architectures.joined(separator: ", ")
            )
        }

        let exports = try execute(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "dyld_info", "-arch", expectedArchitecture, "-exports",
                libraryURL.path,
            ]
        )
        let exportedSymbols = Set(
            exports.split(whereSeparator: \Character.isNewline)
                .compactMap(Self.appleExportedSymbol(from:))
        )

        let linkage = try execute(
            executablePath: "/usr/bin/otool",
            arguments: ["-arch", expectedArchitecture, "-L", libraryURL.path]
        )
        let installNames = linkage.split(whereSeparator: \Character.isNewline)
            .dropFirst()
            .compactMap(Self.appleInstallName(from:))
        guard let installName = installNames.first else {
            throw MojoArtifactError.invalidRuntimeLibrary(
                library: libraryURL.lastPathComponent,
                detail: "no Mach-O install name was reported"
            )
        }
        return MojoRuntimeBinaryInspection(
            architecture: expectedArchitecture,
            installName: installName,
            dynamicDependencies: Array(installNames.dropFirst()),
            exportedSymbols: exportedSymbols
        )
    }

    private func inspectLinux(
        libraryURL: URL,
        target: MojoTargetConfiguration
    ) throws -> MojoRuntimeBinaryInspection {
        let nm = try linuxTool(
            environmentKey: "SWIFT_MOJO_LLVM_NM",
            nativePath: "/usr/bin/nm",
            xcrunTool: "llvm-nm"
        )
        let exports = try execute(
            executablePath: nm.executablePath,
            arguments: nm.prefixArguments + [
                "--dynamic", "--defined-only", "--extern-only", libraryURL.path,
            ]
        )
        let exportedSymbols = Set(
            exports.split(whereSeparator: \Character.isNewline)
                .compactMap(Self.linuxExportedSymbol(from:))
        )

        let metadata = try linuxMetadata(binaryURL: libraryURL)
        let expectedArchitecture = try Self.expectedArchitecture(target: target)
        let actualMachine = Self.elfMachine(from: metadata) ?? "missing"
        guard Self.elfMachine(actualMachine, matches: expectedArchitecture) else {
            throw MojoArtifactError.runtimeLibraryArchitectureMismatch(
                library: libraryURL.lastPathComponent,
                expected: expectedArchitecture,
                actual: actualMachine
            )
        }
        let installName = Self.elfDynamicValue(tag: "SONAME", output: metadata)
            ?? libraryURL.lastPathComponent
        let dependencies = Self.elfDynamicValues(
            tag: "NEEDED",
            output: metadata
        )
        return MojoRuntimeBinaryInspection(
            architecture: expectedArchitecture,
            installName: installName,
            dynamicDependencies: dependencies,
            exportedSymbols: exportedSymbols
        )
    }

    private func appleArchitectures(binaryURL: URL) throws -> [String] {
        try execute(
            executablePath: "/usr/bin/xcrun",
            arguments: ["lipo", "-archs", binaryURL.path]
        ).split(whereSeparator: \Character.isWhitespace).map(String.init)
    }

    private func linuxMetadata(binaryURL: URL) throws -> String {
        let readelf = try linuxTool(
            environmentKey: "SWIFT_MOJO_LLVM_READELF",
            nativePath: "/usr/bin/readelf",
            xcrunTool: "llvm-readelf"
        )
        return try execute(
            executablePath: readelf.executablePath,
            arguments: readelf.prefixArguments + [
                "--file-header", "--dynamic", binaryURL.path,
            ]
        )
    }

    private func linuxTool(
        environmentKey: String,
        nativePath: String,
        xcrunTool: String
    ) throws -> (executablePath: String, prefixArguments: [String]) {
        if let path = environment[environmentKey] {
            guard NSString(string: path).isAbsolutePath else {
                throw MojoArtifactError.invalidArguments(
                    "\(environmentKey) must be an absolute path"
                )
            }
            return (path, [])
        }
#if os(macOS)
        return ("/usr/bin/xcrun", [xcrunTool])
#else
        return (nativePath, [])
#endif
    }

    private func execute(
        executablePath: String,
        arguments: [String]
    ) throws -> String {
        let result = try processRunner.capture(
            executablePath: executablePath,
            arguments: arguments
        )
        guard result.status == 0 else {
            throw MojoArtifactError.commandFailed(
                command: ([executablePath] + arguments).joined(separator: " "),
                status: result.status,
                diagnostic: result.output.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            )
        }
        return result.output
    }

    private static func expectedArchitecture(
        target: MojoTargetConfiguration
    ) throws -> String {
        let architecture = target.triple.split(separator: "-").first.map(String.init)
        switch architecture?.lowercased() {
        case "arm64", "aarch64":
            return "arm64"
        case "x86_64":
            return "x86_64"
        default:
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
    }

    private static func appleExportedSymbol(from line: Substring) -> String? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2,
              fields[0].hasPrefix("0x"),
              let raw = fields.last else {
            return nil
        }
        let symbol = raw.first == "_" ? raw.dropFirst() : raw[...]
        return symbol.isEmpty ? nil : String(symbol)
    }

    private static func appleInstallName(from line: Substring) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let range = trimmed.range(of: " (") {
            return String(trimmed[..<range.lowerBound])
        }
        return trimmed
    }

    private static func linuxExportedSymbol(from line: Substring) -> String? {
        let fields = line.split(whereSeparator: \Character.isWhitespace)
        guard fields.count >= 2,
              let raw = fields.last else {
            return nil
        }
        let symbol = raw.split(separator: "@", maxSplits: 1).first ?? raw
        return symbol.isEmpty ? nil : String(symbol)
    }

    private static func elfMachine(from output: String) -> String? {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("Machine:") else {
                return nil
            }
            return trimmed.dropFirst("Machine:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.first
    }

    private static func elfMachine(
        _ machine: String,
        matches architecture: String
    ) -> Bool {
        switch architecture {
        case "arm64":
            return machine.localizedCaseInsensitiveContains("AArch64")
        case "x86_64":
            return machine.localizedCaseInsensitiveContains("X86-64")
                || machine.localizedCaseInsensitiveContains("x86_64")
        default:
            return false
        }
    }

    private static func elfDynamicValue(
        tag: String,
        output: String
    ) -> String? {
        elfDynamicValues(tag: tag, output: output).first
    }

    private static func elfDynamicValues(
        tag: String,
        output: String
    ) -> [String] {
        output.split(whereSeparator: \Character.isNewline).compactMap { line in
            guard line.contains("(\(tag))"),
                  let start = line.firstIndex(of: "["),
                  let end = line[start...].firstIndex(of: "]"),
                  start < end else {
                return nil
            }
            return String(line[line.index(after: start)..<end])
        }
    }
}
