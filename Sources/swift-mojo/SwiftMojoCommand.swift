import Foundation
import MojoArtifactCore

@main
enum SwiftMojoCommand {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(
                Data("error: \(error)\n".utf8)
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func run(arguments: [String]) throws {
        guard let command = arguments.first else {
            throw MojoArtifactError.invalidArguments(usage)
        }
        let options = try ParsedOptions(arguments: Array(arguments.dropFirst()))
        switch command {
        case "init":
            let layout = try options.packageLayoutIfPresent()
            let output: URL
            if let layout {
                guard options.value("--output-dir") == nil else {
                    throw MojoArtifactError.invalidArguments(
                        "Use either --package-root/--target or --output-dir"
                    )
                }
                try layout.validatePackageTarget()
                output = layout.outputDirectoryURL
            } else {
                output = try options.requiredURL("--output-dir")
            }
            try options.rejectUnknown(
                allowed: ["--output-dir", "--package-root", "--target"]
            )
            let disposition = try MojoArtifactInitializer().initialize(
                outputDirectoryURL: output
            )
            if let layout {
                print(
                    initializationMessage(
                        layout: layout,
                        disposition: disposition
                    )
                )
            } else {
                let prefix = disposition == .initialized
                    ? "Initialized"
                    : "Already initialized"
                print("\(prefix) static artifact storage at \(output.path). Run 'swift-mojo prepare' before building.")
            }
        case "prepare":
            let layout = try options.packageLayoutIfPresent()
            let sourceURLs: [URL]
            let outputDirectoryURL: URL
            if let layout {
                guard options.urls("--source").isEmpty,
                      options.value("--output-dir") == nil else {
                    throw MojoArtifactError.invalidArguments(
                        "Use either --package-root/--target or explicit --source/--output-dir options"
                    )
                }
                sourceURLs = try layout.sourceURLs()
                outputDirectoryURL = layout.outputDirectoryURL
            } else {
                sourceURLs = options.urls("--source")
                outputDirectoryURL = try options.requiredURL("--output-dir")
            }
            let prepareOptions = try MojoPrepareOptions(
                sourceURLs: sourceURLs,
                outputDirectoryURL: outputDirectoryURL,
                targetTriple: options.value("--target-triple")
                    ?? defaultTargetTriple,
                targetCPU: options.value("--target-cpu") ?? "generic"
            )
            try options.rejectUnknown(
                allowed: [
                    "--source",
                    "--output-dir",
                    "--target-triple",
                    "--target-cpu",
                    "--package-root",
                    "--target",
                ]
            )
            let result = try MojoArtifactPreparer().prepare(
                options: prepareOptions
            )
            print(
                "\(result.disposition == .reused ? "Reused" : "Prepared") \(result.manifest.bindings.count) Mojo binding(s) for \(result.manifest.target.triple)/\(result.manifest.target.cpu)."
            )
        case "verify":
            let verifyOptions = try MojoVerifyOptions(
                sourceURLs: options.urls("--source"),
                outputDirectoryURL: options.requiredURL("--output-dir"),
                generatedSourceURL: options.requiredURL("--generated-source"),
                targetTriple: options.value("--target-triple")
                    ?? defaultTargetTriple,
                targetCPU: options.value("--target-cpu") ?? "generic"
            )
            try options.rejectUnknown(
                allowed: [
                    "--source",
                    "--output-dir",
                    "--generated-source",
                    "--target-triple",
                    "--target-cpu",
                ]
            )
            let manifest = try MojoArtifactVerifier().verify(
                options: verifyOptions
            )
            print(
                "Verified \(manifest.bindings.count) Mojo binding(s); artifact SHA-256 \(manifest.artifactDigest)."
            )
        case "help", "--help", "-h":
            print(usage)
        default:
            throw MojoArtifactError.invalidArguments(
                "Unknown command '\(command)'.\n\n\(usage)"
            )
        }
    }

    private static var defaultTargetTriple: String {
#if arch(arm64) && os(macOS)
        "arm64-apple-macosx14.0"
#else
        "unsupported-host"
#endif
    }

    private static let usage = """
    Usage:
      swift-mojo init --package-root <path> --target <target>
      swift-mojo prepare --package-root <path> --target <target> [--target-triple <triple>] [--target-cpu <cpu>]
      swift-mojo init --output-dir <path>
      swift-mojo prepare --source <file.swift> [--source <file.swift> ...] --output-dir <path> [--target-triple <triple>] [--target-cpu <cpu>]
      swift-mojo verify --source <file.swift> [--source <file.swift> ...] --output-dir <path> --generated-source <file.swift> [--target-triple <triple>] [--target-cpu <cpu>]
    """

    private static func initializationMessage(
        layout: MojoPackageLayout,
        disposition: MojoInitializationDisposition
    ) -> String {
        let prefix = disposition == .initialized
            ? "Initialized"
            : "Already initialized"
        return """
        \(prefix) static artifact storage at \(layout.outputDirectoryURL.path).

        Add this binary target to Package.swift:

            .binaryTarget(
                name: "GeneratedMojoABI",
                path: "\(layout.binaryTargetRelativePath)"
            )

        Add "GeneratedMojoABI" and the Mojo product to target '\(layout.targetName)', attach MojoBuildPlugin, then run:

            swift-mojo prepare --package-root \(layout.packageRootURL.path) --target \(layout.targetName)
        """
    }
}

private struct ParsedOptions {
    private let values: [String: [String]]

    init(arguments: [String]) throws {
        var values: [String: [String]] = [:]
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let option = arguments[index]
            guard option.hasPrefix("--") else {
                throw MojoArtifactError.invalidArguments(
                    "Unexpected positional argument '\(option)'"
                )
            }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex,
                  !arguments[valueIndex].hasPrefix("--") else {
                throw MojoArtifactError.invalidArguments(
                    "Missing value for \(option)"
                )
            }
            values[option, default: []].append(arguments[valueIndex])
            index = arguments.index(after: valueIndex)
        }
        self.values = values
    }

    func value(_ option: String) -> String? {
        values[option]?.last
    }

    func urls(_ option: String) -> [URL] {
        (values[option] ?? []).map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
    }

    func requiredURL(_ option: String) throws -> URL {
        guard let value = value(option) else {
            throw MojoArtifactError.invalidArguments(
                "Missing required option \(option)"
            )
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    func packageLayoutIfPresent() throws -> MojoPackageLayout? {
        let packageRoot = value("--package-root")
        let target = value("--target")
        guard packageRoot != nil || target != nil else {
            return nil
        }
        guard let target else {
            throw MojoArtifactError.invalidArguments(
                "--target is required when --package-root is used"
            )
        }
        let rootURL = packageRoot.map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try MojoPackageLayout(
            packageRootURL: rootURL,
            targetName: target
        )
    }

    func rejectUnknown(allowed: Set<String>) throws {
        let unknown = Set(values.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "Unknown option(s): \(unknown.sorted().joined(separator: ", "))"
            )
        }
        for (option, optionValues) in values
        where option != "--source" && optionValues.count > 1 {
            throw MojoArtifactError.invalidArguments(
                "Option \(option) may be supplied only once"
            )
        }
    }
}
