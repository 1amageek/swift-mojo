import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeLibraryBundleOptions: Equatable, Sendable {
    package let outputDirectoryURL: URL
    package let identity: MojoArtifactIdentity
    package let compilerVersion: String
    package let inputGraphDigest: String
    package let inputGraphIdentifier: UInt64
    package let generatedSourceDigest: String
    package let sourceMapDigest: String
    package let exportedSymbols: Set<String>
    package let header: String
    package let moduleMap: String
    package let runtimeReceiptOptions: MojoRuntimeReceiptOptions

    package var objectURL: URL { runtimeReceiptOptions.objectURL }
    package var libraryURLs: [URL] { runtimeReceiptOptions.libraryURLs }
    package var target: MojoTargetConfiguration { runtimeReceiptOptions.target }

    package var primaryLibraryName: String {
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            return "lib\(identity.moduleName).dylib"
        }
        return "lib\(identity.moduleName).so"
    }

    package init(
        outputDirectoryURL: URL,
        identity: MojoArtifactIdentity,
        compilerVersion: String,
        inputGraph: MojoInputGraph,
        objectURL: URL,
        libraryURLs: [URL],
        target: MojoTargetConfiguration,
        allowedSystemDependencies: Set<String> = [],
        renderer: MojoStaticSourceRenderer = MojoStaticSourceRenderer()
    ) throws {
        let rendered = renderer.render(
            inputGraph: inputGraph,
            identity: identity
        )
        try self.init(
            outputDirectoryURL: outputDirectoryURL,
            identity: identity,
            compilerVersion: compilerVersion,
            inputGraphDigest: inputGraph.digest,
            inputGraphIdentifier: inputGraph.digestIdentifier,
            generatedSourceDigest: MojoCanonicalDigest.hex(
                Data(rendered.source.utf8)
            ),
            sourceMapDigest: MojoCanonicalDigest.hex(
                try rendered.sourceMap.encode()
            ),
            exportedSymbols: renderer.exportedSymbols(
                identity: identity,
                inputGraph: inputGraph
            ),
            header: renderer.header(
                identity: identity,
                inputGraph: inputGraph
            ),
            moduleMap: renderer.moduleMap(identity: identity),
            objectURL: objectURL,
            libraryURLs: libraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )
    }

    package init(
        outputDirectoryURL: URL,
        identity: MojoArtifactIdentity,
        compilerVersion: String,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        generatedSourceDigest: String,
        sourceMapDigest: String,
        exportedSymbols: Set<String>,
        header: String,
        moduleMap: String,
        objectURL: URL,
        libraryURLs: [URL],
        target: MojoTargetConfiguration,
        allowedSystemDependencies: Set<String> = []
    ) throws {
        guard !compilerVersion.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
              Self.isSHA256Digest(inputGraphDigest),
              Self.isSHA256Digest(generatedSourceDigest),
              Self.isSHA256Digest(sourceMapDigest) else {
            throw MojoArtifactError.invalidArguments(
                "A runtime library bundle requires compiler and generated graph provenance"
            )
        }
        guard !exportedSymbols.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "A runtime library bundle requires at least one exported symbol"
            )
        }
        guard !header.isEmpty, !moduleMap.isEmpty else {
            throw MojoArtifactError.invalidArguments(
                "A runtime library bundle requires a header and module map"
            )
        }
        let receiptOptions = try MojoRuntimeReceiptOptions(
            objectURL: objectURL,
            libraryURLs: libraryURLs,
            target: target,
            allowedSystemDependencies: allowedSystemDependencies
        )
        let output = outputDirectoryURL.standardizedFileURL
        let outputPrefix = output.path.hasSuffix("/")
            ? output.path
            : output.path + "/"
        let inputs = [receiptOptions.objectURL] + receiptOptions.libraryURLs
        guard !inputs.contains(where: {
            $0.path == output.path || $0.path.hasPrefix(outputPrefix)
        }) else {
            throw MojoArtifactError.invalidArguments(
                "The runtime library bundle output must not contain its object or library inputs"
            )
        }
        let primaryName: String
        let triple = target.triple.lowercased()
        if triple.contains("-apple-") {
            primaryName = "lib\(identity.moduleName).dylib"
        } else if triple.contains("-linux-") {
            primaryName = "lib\(identity.moduleName).so"
        } else {
            throw MojoArtifactError.unsupportedTarget(target.triple)
        }
        guard !receiptOptions.libraryURLs.contains(where: {
            $0.lastPathComponent == primaryName
        }) else {
            throw MojoArtifactError.invalidArguments(
                "The primary runtime library name conflicts with a dependency"
            )
        }
        self.outputDirectoryURL = output
        self.identity = identity
        self.compilerVersion = compilerVersion
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.generatedSourceDigest = generatedSourceDigest
        self.sourceMapDigest = sourceMapDigest
        self.exportedSymbols = exportedSymbols
        self.header = header
        self.moduleMap = moduleMap
        self.runtimeReceiptOptions = receiptOptions
    }

    private static func isSHA256Digest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }
}
