import Foundation
import MojoBindingCore
import MojoCompilerCore

package struct MojoRuntimeLibraryBundleManifest: Codable, Equatable, Sendable {
    package struct Binding: Codable, Equatable, Sendable {
        package let bindingID: UInt64
        package let functionName: String
        package let signature: String
        package let sessionFactoryFunctionName: String?

        package init(_ binding: MojoBinding) {
            self.bindingID = binding.bindingID
            self.functionName = binding.functionName
            self.signature = binding.signature.rawValue
            switch binding.implementation {
            case .sessionExternal(_, _, let sessionFactory),
                 .sessionResource(_, _, _, _, _, _, let sessionFactory):
                self.sessionFactoryFunctionName = sessionFactory
            case .inline, .external, .session:
                self.sessionFactoryFunctionName = nil
            }
        }

        package init(
            bindingID: UInt64,
            functionName: String,
            signature: String,
            sessionFactoryFunctionName: String? = nil
        ) {
            self.bindingID = bindingID
            self.functionName = functionName
            self.signature = signature
            self.sessionFactoryFunctionName = sessionFactoryFunctionName
        }
    }

    package struct File: Codable, Equatable, Sendable {
        package let relativePath: String
        package let digest: String

        package init(relativePath: String, digest: String) {
            self.relativePath = relativePath
            self.digest = digest
        }
    }

    package static let currentSchemaVersion = 3
    package static let fileName = "RuntimeLibraryBundle.json"
    package static let receiptFileName = "RuntimeReceipt.json"

    package let schemaVersion: Int
    package let receiptDigest: String
    package let target: MojoTargetConfiguration
    package let moduleName: String
    package let compilerVersion: String
    package let inputGraphDigest: String
    package let inputGraphIdentifier: UInt64
    package let generatedSourceDigest: String
    package let sourceMapDigest: String
    package let bindings: [Binding]
    package let loaderSearchPath: String
    package let library: File
    package let runtimeLibraries: [File]
    package let interfaceHeader: File
    package let moduleMap: File
    package let exportedSymbols: [String]
    package let systemDependencies: [String]

    package init(
        receiptDigest: String,
        target: MojoTargetConfiguration,
        moduleName: String,
        compilerVersion: String,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        generatedSourceDigest: String,
        sourceMapDigest: String,
        bindings: [Binding],
        loaderSearchPath: String,
        library: File,
        runtimeLibraries: [File],
        interfaceHeader: File,
        moduleMap: File,
        exportedSymbols: [String],
        systemDependencies: [String]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.receiptDigest = receiptDigest
        self.target = target
        self.moduleName = moduleName
        self.compilerVersion = compilerVersion
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.generatedSourceDigest = generatedSourceDigest
        self.sourceMapDigest = sourceMapDigest
        self.bindings = bindings.sorted(by: Self.bindingPrecedes)
        self.loaderSearchPath = loaderSearchPath
        self.library = library
        self.runtimeLibraries = runtimeLibraries.sorted {
            $0.relativePath < $1.relativePath
        }
        self.interfaceHeader = interfaceHeader
        self.moduleMap = moduleMap
        self.exportedSymbols = exportedSymbols.sorted()
        self.systemDependencies = systemDependencies.sorted()
    }

    package var digest: String {
        var components = [
            "schema=\(schemaVersion)",
            "receipt=\(receiptDigest)",
            "target=\(target.identity)",
            "module=\(moduleName)",
            "compiler=\(compilerVersion)",
            "input-graph=\(inputGraphDigest)",
            "input-graph-identifier=\(inputGraphIdentifier)",
            "generated-source=\(generatedSourceDigest)",
            "source-map=\(sourceMapDigest)",
            "loader=\(loaderSearchPath)",
            "library=\(library.relativePath)",
            "library-digest=\(library.digest)",
            "header=\(interfaceHeader.relativePath)",
            "header-digest=\(interfaceHeader.digest)",
            "module-map=\(moduleMap.relativePath)",
            "module-map-digest=\(moduleMap.digest)",
        ]
        for runtimeLibrary in runtimeLibraries {
            components.append("runtime=\(runtimeLibrary.relativePath)")
            components.append("runtime-digest=\(runtimeLibrary.digest)")
        }
        for binding in bindings {
            components.append("binding-id=\(binding.bindingID)")
            components.append("binding-function=\(binding.functionName)")
            components.append("binding-signature=\(binding.signature)")
            components.append(
                "binding-session-factory=\(binding.sessionFactoryFunctionName ?? "-")"
            )
        }
        components.append(contentsOf: exportedSymbols.map { "export=\($0)" })
        components.append(
            contentsOf: systemDependencies.map { "system=\($0)" }
        )
        let canonical = components.map {
            "\($0.utf8.count):\($0)"
        }.joined(separator: "|")
        return MojoCanonicalDigest.hex(canonical)
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> Self {
        let manifest: Self
        do {
            manifest = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw MojoArtifactError.invalidRuntimeBundle(
                String(describing: error)
            )
        }
        guard manifest.schemaVersion == currentSchemaVersion else {
            throw MojoArtifactError.invalidRuntimeBundle(
                "unsupported runtime library schema version \(manifest.schemaVersion)"
            )
        }
        return manifest
    }

    package static func bindingPrecedes(
        _ lhs: Binding,
        _ rhs: Binding
    ) -> Bool {
        if lhs.bindingID == rhs.bindingID {
            return lhs.functionName < rhs.functionName
        }
        return lhs.bindingID < rhs.bindingID
    }
}
