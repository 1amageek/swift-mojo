import Foundation
import Testing

@Suite("Runtime worker acceptance public boundary")
struct RuntimeWorkerAcceptancePublicBoundaryTests {
    @Test(.timeLimit(.minutes(1)))
    func consumerUsesOnlyPublicRuntimeProducts() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent(
            "Fixtures/Consumer/Sources/RuntimeWorkerAcceptanceConsumer/RuntimeWorkerAcceptanceConsumer.swift"
        )
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let targets = try Self.dumpPackage(at: root).targets.filter {
            $0.name == "RuntimeWorkerAcceptanceConsumer"
        }
        guard targets.count == 1, let consumer = targets.first else {
            throw BoundaryError.consumerTargetCount(targets.count)
        }
        let expectedDependencies: Set<DumpDependency> = [
            .product(name: "MojoRuntime", package: "swift-mojo"),
            .product(name: "MojoRuntimeWorker", package: "swift-mojo"),
        ]
        #expect(consumer.dependencies.count == expectedDependencies.count)
        #expect(Set(consumer.dependencies) == expectedDependencies)
        #expect((consumer.pluginUsages ?? []).isEmpty)

        let importLines = source.split(whereSeparator: \Character.isNewline).map {
            $0.split(whereSeparator: \Character.isWhitespace)
        }.filter { $0.contains("import") }
        let imports = importLines.compactMap { words -> String? in
            guard let index = words.firstIndex(of: "import") else { return nil }
            let moduleIndex = words.index(after: index)
            guard moduleIndex < words.endIndex else { return nil }
            return String(words[moduleIndex].split(separator: ".")[0])
        }
        let expectedImports: Set<String> = ["Foundation", "MojoRuntime", "MojoRuntimeWorker"]
        #expect(imports.count == importLines.count)
        #expect(imports.count == expectedImports.count)
        #expect(Set(imports) == expectedImports)
        for forbidden in [
            "import MojoArtifactCore", "import MojoRuntimeProtocolCore",
            "import MojoPOSIXSupport", "dlopen", "dlsym", "Process(",
        ] {
            #expect(!source.contains(forbidden))
        }
    }

    private static func dumpPackage(at root: URL) throws -> PackageDump {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-worker-package-dump-\(UUID().uuidString)")
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        process.arguments = [
            "package", "dump-package", "--package-path", root.path,
            "--scratch-path", scratch.path,
        ]
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch {
            throw BoundaryError.launchFailed(String(describing: error))
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(decoding: errorData, as: UTF8.self)
        do { try FileManager.default.removeItem(at: scratch) } catch {
            throw BoundaryError.scratchRemovalFailed(String(describing: error))
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0
        else {
            throw BoundaryError.commandFailed(process.terminationStatus, errorText)
        }
        do { return try JSONDecoder().decode(PackageDump.self, from: data) } catch {
            throw BoundaryError.decodeFailed(String(describing: error))
        }
    }
}

private struct PackageDump: Decodable { let targets: [DumpTarget] }

private struct DumpTarget: Decodable {
    let name: String
    let dependencies: [DumpDependency]
    let pluginUsages: [DumpPluginUsage]?
}

private enum DumpDependency: Decodable, Hashable {
    case product(name: String, package: String)
    case other

    private enum Keys: String, CodingKey { case product, byName, target }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: Keys.self)
        guard values.allKeys == [.product] else {
            self = .other
            return
        }
        var product = try values.nestedUnkeyedContainer(forKey: .product)
        self = .product(
            name: try product.decode(String.self),
            package: try product.decode(String.self)
        )
    }
}

private struct DumpPluginUsage: Decodable {}

private enum BoundaryError: Error {
    case commandFailed(Int32, String)
    case consumerTargetCount(Int)
    case decodeFailed(String)
    case launchFailed(String)
    case scratchRemovalFailed(String)
}
