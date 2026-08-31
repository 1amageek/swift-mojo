import Foundation
import MojoBindingCore
import MojoCompilerCore
import MojoRuntimeProtocolCore

package struct MojoRuntimeWorkerBundleManifest: Codable, Equatable, Sendable {
    package struct Binding: Codable, Equatable, Sendable {
        package let bindingID: UInt64
        package let functionName: String
        package let signature: MojoBinding.Signature
        package let sessionFactoryFunctionName: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case bindingID
            case functionName
            case signature
            case sessionFactoryFunctionName
        }

        package init(_ binding: MojoRuntimeWorkerBinding) {
            self.bindingID = binding.bindingID
            self.functionName = binding.functionName
            self.signature = binding.signature
            self.sessionFactoryFunctionName = binding.sessionFactoryFunctionName
        }

        package init(
            bindingID: UInt64,
            functionName: String,
            signature: MojoBinding.Signature,
            sessionFactoryFunctionName: String?
        ) {
            self.bindingID = bindingID
            self.functionName = functionName
            self.signature = signature
            self.sessionFactoryFunctionName = sessionFactoryFunctionName
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                bindingID: try container.decode(UInt64.self, forKey: .bindingID),
                functionName: try container.decode(String.self, forKey: .functionName),
                signature: try container.decode(
                    MojoBinding.Signature.self,
                    forKey: .signature
                ),
                sessionFactoryFunctionName: try container.decodeIfPresent(
                    String.self,
                    forKey: .sessionFactoryFunctionName
                )
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bindingID, forKey: .bindingID)
            try container.encode(functionName, forKey: .functionName)
            try container.encode(signature, forKey: .signature)
            if let sessionFactoryFunctionName {
                try container.encode(
                    sessionFactoryFunctionName,
                    forKey: .sessionFactoryFunctionName
                )
            } else {
                try container.encodeNil(forKey: .sessionFactoryFunctionName)
            }
        }

        fileprivate var workerBinding: MojoRuntimeWorkerBinding {
            MojoRuntimeWorkerBinding(
                bindingID: bindingID,
                functionName: functionName,
                signature: signature,
                sessionFactoryFunctionName: sessionFactoryFunctionName
            )
        }

        fileprivate var canonicalRecord: String {
            workerBinding.canonicalRecord
        }
    }

    package struct SemanticIdentity: Codable, Equatable, Sendable {
        package let workerABIVersion: UInt32
        package let protocolVersion: UInt16
        package let sourceGraphDigest: String
        package let sourceGraphIdentifier: UInt64
        package let inputGraphDigest: String
        package let inputGraphIdentifier: UInt64
        package let generationPipelineDigest: String
        package let bindings: [Binding]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case workerABIVersion
            case protocolVersion
            case sourceGraphDigest
            case sourceGraphIdentifier
            case inputGraphDigest
            case inputGraphIdentifier
            case generationPipelineDigest
            case bindings
        }

        package init(
            workerABIVersion: UInt32,
            protocolVersion: UInt16,
            sourceGraphDigest: String,
            sourceGraphIdentifier: UInt64,
            inputGraphDigest: String,
            inputGraphIdentifier: UInt64,
            generationPipelineDigest: String,
            bindings: [Binding]
        ) throws {
            guard workerABIVersion
                    == MojoRuntimeWorkerRenderer.workerABIVersion else {
                throw invalidWorkerBundle(
                    "unsupported worker ABI version \(workerABIVersion)"
                )
            }
            guard protocolVersion == MojoRuntimeProtocol.version else {
                throw invalidWorkerBundle(
                    "unsupported worker protocol version \(protocolVersion)"
                )
            }
            try requireWorkerBundleDigests([
                sourceGraphDigest,
                inputGraphDigest,
                generationPipelineDigest,
            ])
            guard MojoCanonicalDigest.identifier(
                fromSHA256Hex: sourceGraphDigest
            ) == sourceGraphIdentifier,
                MojoCanonicalDigest.identifier(
                    fromSHA256Hex: inputGraphDigest
                ) == inputGraphIdentifier else {
                throw invalidWorkerBundle(
                    "worker graph digest and identifier pairs are inconsistent"
                )
            }
            guard bindings.allSatisfy({ binding in
                binding.bindingID == MojoBinding.bindingIdentifier(
                    functionName: binding.functionName,
                    signature: binding.signature
                )
            }) else {
                throw invalidWorkerBundle(
                    "worker binding IDs do not match their canonical ABI identities"
                )
            }
            let table: MojoRuntimeWorkerBindingTable
            do {
                table = try MojoRuntimeWorkerBindingTable(
                    bindings: bindings.map(\.workerBinding)
                )
            } catch {
                throw invalidWorkerBundle(
                    "invalid worker binding table: \(error)"
                )
            }
            guard table.bindings == bindings.map(\.workerBinding) else {
                throw invalidWorkerBundle(
                    "worker bindings must use canonical binding-ID order"
                )
            }
            self.workerABIVersion = workerABIVersion
            self.protocolVersion = protocolVersion
            self.sourceGraphDigest = sourceGraphDigest
            self.sourceGraphIdentifier = sourceGraphIdentifier
            self.inputGraphDigest = inputGraphDigest
            self.inputGraphIdentifier = inputGraphIdentifier
            self.generationPipelineDigest = generationPipelineDigest
            self.bindings = bindings
        }

        package init(
            inputGraph: MojoInputGraph,
            generationPipelineDigest: String,
            bindingTable: MojoRuntimeWorkerBindingTable,
            workerABIVersion: UInt32 = MojoRuntimeWorkerRenderer.workerABIVersion,
            protocolVersion: UInt16 = MojoRuntimeProtocol.version
        ) throws {
            try self.init(
                workerABIVersion: workerABIVersion,
                protocolVersion: protocolVersion,
                sourceGraphDigest: inputGraph.bindingGraph.digest,
                sourceGraphIdentifier: inputGraph.bindingGraph.digestIdentifier,
                inputGraphDigest: inputGraph.digest,
                inputGraphIdentifier: inputGraph.digestIdentifier,
                generationPipelineDigest: generationPipelineDigest,
                bindings: bindingTable.bindings.map(Binding.init)
            )
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                workerABIVersion: try container.decode(
                    UInt32.self,
                    forKey: .workerABIVersion
                ),
                protocolVersion: try container.decode(
                    UInt16.self,
                    forKey: .protocolVersion
                ),
                sourceGraphDigest: try container.decode(
                    String.self,
                    forKey: .sourceGraphDigest
                ),
                sourceGraphIdentifier: try container.decode(
                    UInt64.self,
                    forKey: .sourceGraphIdentifier
                ),
                inputGraphDigest: try container.decode(
                    String.self,
                    forKey: .inputGraphDigest
                ),
                inputGraphIdentifier: try container.decode(
                    UInt64.self,
                    forKey: .inputGraphIdentifier
                ),
                generationPipelineDigest: try container.decode(
                    String.self,
                    forKey: .generationPipelineDigest
                ),
                bindings: try container.decode([Binding].self, forKey: .bindings)
            )
        }

        package var bindingTable: MojoRuntimeWorkerBindingTable {
            get throws {
                try MojoRuntimeWorkerBindingTable(
                    bindings: bindings.map(\.workerBinding)
                )
            }
        }

        fileprivate var canonicalRecords: [String] {
            [
                "worker-abi=\(workerABIVersion)",
                "protocol-version=\(protocolVersion)",
                "source-graph=\(sourceGraphDigest)",
                "source-graph-identifier=\(sourceGraphIdentifier)",
                "input-graph=\(inputGraphDigest)",
                "input-graph-identifier=\(inputGraphIdentifier)",
                "generation-pipeline=\(generationPipelineDigest)",
            ] + bindings.map { "binding=\($0.canonicalRecord)" }
        }
    }

    package struct GeneratedInputs: Codable, Equatable, Sendable {
        package let generatedMojoSourceDigest: String
        package let generatedCWorkerSourceDigest: String
        package let sourceMapDigest: String
        package let generatedMojoObjectDigest: String
        package let generatedCWorkerObjectDigest: String
        package let compilerVersion: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case generatedMojoSourceDigest
            case generatedCWorkerSourceDigest
            case sourceMapDigest
            case generatedMojoObjectDigest
            case generatedCWorkerObjectDigest
            case compilerVersion
        }

        package init(
            generatedMojoSourceDigest: String,
            generatedCWorkerSourceDigest: String,
            sourceMapDigest: String,
            generatedMojoObjectDigest: String,
            generatedCWorkerObjectDigest: String,
            compilerVersion: String
        ) throws {
            try requireWorkerBundleDigests([
                generatedMojoSourceDigest,
                generatedCWorkerSourceDigest,
                sourceMapDigest,
                generatedMojoObjectDigest,
                generatedCWorkerObjectDigest,
            ])
            guard !compilerVersion.isEmpty,
                  compilerVersion.utf8.count <= 4_096 else {
                throw invalidWorkerBundle(
                    "compiler version must be nonempty and bounded"
                )
            }
            self.generatedMojoSourceDigest = generatedMojoSourceDigest
            self.generatedCWorkerSourceDigest = generatedCWorkerSourceDigest
            self.sourceMapDigest = sourceMapDigest
            self.generatedMojoObjectDigest = generatedMojoObjectDigest
            self.generatedCWorkerObjectDigest = generatedCWorkerObjectDigest
            self.compilerVersion = compilerVersion
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                generatedMojoSourceDigest: try container.decode(
                    String.self,
                    forKey: .generatedMojoSourceDigest
                ),
                generatedCWorkerSourceDigest: try container.decode(
                    String.self,
                    forKey: .generatedCWorkerSourceDigest
                ),
                sourceMapDigest: try container.decode(
                    String.self,
                    forKey: .sourceMapDigest
                ),
                generatedMojoObjectDigest: try container.decode(
                    String.self,
                    forKey: .generatedMojoObjectDigest
                ),
                generatedCWorkerObjectDigest: try container.decode(
                    String.self,
                    forKey: .generatedCWorkerObjectDigest
                ),
                compilerVersion: try container.decode(
                    String.self,
                    forKey: .compilerVersion
                )
            )
        }

        fileprivate var canonicalRecords: [String] {
            [
                "mojo-source=\(generatedMojoSourceDigest)",
                "c-worker-source=\(generatedCWorkerSourceDigest)",
                "source-map=\(sourceMapDigest)",
                "mojo-object=\(generatedMojoObjectDigest)",
                "c-worker-object=\(generatedCWorkerObjectDigest)",
                "compiler=\(compilerVersion)",
            ]
        }
    }

    package struct MessageKind: Codable, Equatable, Sendable {
        package let rawValue: UInt16
        package let name: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case rawValue
            case name
        }

        package init(_ kind: MojoRuntimeFrameKind) {
            self.rawValue = kind.rawValue
            self.name = kind.name
        }

        package init(rawValue: UInt16, name: String) {
            self.rawValue = rawValue
            self.name = name
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                rawValue: try container.decode(UInt16.self, forKey: .rawValue),
                name: try container.decode(String.self, forKey: .name)
            )
        }

        fileprivate var canonicalRecord: String {
            "\(rawValue):\(name)"
        }
    }

    package struct ProtocolRecord: Codable, Equatable, Sendable {
        package static let descriptor: Int32 = 3
        package static let byteOrder = "little-endian"

        package let version: UInt16
        package let descriptor: Int32
        package let headerByteCount: Int
        package let byteOrder: String
        package let maximumFramePayloadBytes: UInt64
        package let maximumInFlightRequests: Int
        package let messageKinds: [MessageKind]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version
            case descriptor
            case headerByteCount
            case byteOrder
            case maximumFramePayloadBytes
            case maximumInFlightRequests
            case messageKinds
        }

        package init(maximumFramePayloadBytes: UInt64) throws {
            try self.init(
                version: MojoRuntimeProtocol.version,
                descriptor: Self.descriptor,
                headerByteCount: MojoRuntimeProtocol.headerByteCount,
                byteOrder: Self.byteOrder,
                maximumFramePayloadBytes: maximumFramePayloadBytes,
                maximumInFlightRequests:
                    MojoRuntimeProtocol.maximumInFlightRequests,
                messageKinds: MojoRuntimeProtocol.kindTable.map(MessageKind.init)
            )
        }

        package init(
            version: UInt16,
            descriptor: Int32,
            headerByteCount: Int,
            byteOrder: String,
            maximumFramePayloadBytes: UInt64,
            maximumInFlightRequests: Int,
            messageKinds: [MessageKind]
        ) throws {
            guard version == MojoRuntimeProtocol.version else {
                throw invalidWorkerBundle(
                    "unsupported protocol version \(version)"
                )
            }
            guard descriptor == Self.descriptor else {
                throw invalidWorkerBundle(
                    "worker protocol descriptor must be \(Self.descriptor)"
                )
            }
            guard headerByteCount == MojoRuntimeProtocol.headerByteCount else {
                throw invalidWorkerBundle(
                    "worker protocol header must be \(MojoRuntimeProtocol.headerByteCount) bytes"
                )
            }
            guard byteOrder == Self.byteOrder else {
                throw invalidWorkerBundle(
                    "worker protocol byte order must be \(Self.byteOrder)"
                )
            }
            do {
                _ = try MojoRuntimeProtocolLimits(
                    maximumFramePayloadBytes: maximumFramePayloadBytes
                )
            } catch {
                throw invalidWorkerBundle(
                    "worker protocol payload limit is invalid"
                )
            }
            guard maximumInFlightRequests
                    == MojoRuntimeProtocol.maximumInFlightRequests else {
                throw invalidWorkerBundle(
                    "worker protocol must admit exactly one in-flight request"
                )
            }
            let expectedKinds = MojoRuntimeProtocol.kindTable.map(MessageKind.init)
            guard messageKinds == expectedKinds else {
                throw invalidWorkerBundle(
                    "worker protocol message-kind table is not canonical"
                )
            }
            self.version = version
            self.descriptor = descriptor
            self.headerByteCount = headerByteCount
            self.byteOrder = byteOrder
            self.maximumFramePayloadBytes = maximumFramePayloadBytes
            self.maximumInFlightRequests = maximumInFlightRequests
            self.messageKinds = messageKinds
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                version: try container.decode(UInt16.self, forKey: .version),
                descriptor: try container.decode(Int32.self, forKey: .descriptor),
                headerByteCount: try container.decode(
                    Int.self,
                    forKey: .headerByteCount
                ),
                byteOrder: try container.decode(String.self, forKey: .byteOrder),
                maximumFramePayloadBytes: try container.decode(
                    UInt64.self,
                    forKey: .maximumFramePayloadBytes
                ),
                maximumInFlightRequests: try container.decode(
                    Int.self,
                    forKey: .maximumInFlightRequests
                ),
                messageKinds: try container.decode(
                    [MessageKind].self,
                    forKey: .messageKinds
                )
            )
        }

        fileprivate var canonicalRecords: [String] {
            [
                "version=\(version)",
                "descriptor=\(descriptor)",
                "header=\(headerByteCount)",
                "byte-order=\(byteOrder)",
                "maximum-payload=\(maximumFramePayloadBytes)",
                "maximum-in-flight=\(maximumInFlightRequests)",
            ] + messageKinds.map { "kind=\($0.canonicalRecord)" }
        }
    }

    package struct File: Codable, Equatable, Sendable {
        package let relativePath: String
        package let digest: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case relativePath
            case digest
        }

        package init(relativePath: String, digest: String) throws {
            guard isWorkerBundleRelativePath(relativePath) else {
                throw invalidWorkerBundle(
                    "worker bundle file path '\(relativePath)' is not a normalized relative path"
                )
            }
            try requireWorkerBundleDigests([digest])
            self.relativePath = relativePath
            self.digest = digest
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                relativePath: try container.decode(
                    String.self,
                    forKey: .relativePath
                ),
                digest: try container.decode(String.self, forKey: .digest)
            )
        }

        fileprivate var canonicalRecords: [String] {
            ["path=\(relativePath)", "digest=\(digest)"]
        }
    }

    package struct RuntimeBundleRecord: Codable, Equatable, Sendable {
        package let manifestDigest: String
        package let receiptDigest: String
        package let executable: File
        package let libraries: [File]
        package let loaderSearchPath: String
        package let systemDependencies: [String]
        package let programInterpreter: String?

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case manifestDigest
            case receiptDigest
            case executable
            case libraries
            case loaderSearchPath
            case systemDependencies
            case programInterpreter
        }

        package init(
            manifestDigest: String,
            receiptDigest: String,
            executable: File,
            libraries: [File],
            loaderSearchPath: String,
            systemDependencies: [String],
            programInterpreter: String?
        ) throws {
            try requireWorkerBundleDigests([manifestDigest, receiptDigest])
            guard !loaderSearchPath.isEmpty,
                  loaderSearchPath.utf8.count <= 4_096 else {
                throw invalidWorkerBundle(
                    "runtime loader search path must be nonempty and bounded"
                )
            }
            guard isStrictlySortedWorkerBundleFiles(libraries) else {
                throw invalidWorkerBundle(
                    "runtime libraries must have unique canonical path order"
                )
            }
            guard !libraries.contains(where: {
                $0.relativePath == executable.relativePath
            }) else {
                throw invalidWorkerBundle(
                    "runtime executable path duplicates a library path"
                )
            }
            guard isStrictlySortedWorkerBundleStrings(systemDependencies) else {
                throw invalidWorkerBundle(
                    "system dependencies must have unique canonical order"
                )
            }
            guard programInterpreter?.isEmpty != true,
                  (programInterpreter?.utf8.count ?? 0) <= 4_096 else {
                throw invalidWorkerBundle(
                    "runtime program interpreter must be nil or nonempty and bounded"
                )
            }
            self.manifestDigest = manifestDigest
            self.receiptDigest = receiptDigest
            self.executable = executable
            self.libraries = libraries
            self.loaderSearchPath = loaderSearchPath
            self.systemDependencies = systemDependencies
            self.programInterpreter = programInterpreter
        }

        package init(
            manifestDigest: String,
            manifest: MojoRuntimeBundleManifest
        ) throws {
            try self.init(
                manifestDigest: manifestDigest,
                receiptDigest: manifest.receiptDigest,
                executable: File(
                    relativePath: manifest.executable.relativePath,
                    digest: manifest.executable.digest
                ),
                libraries: try manifest.libraries.map {
                    try File(
                        relativePath: $0.relativePath,
                        digest: $0.digest
                    )
                },
                loaderSearchPath: manifest.loaderSearchPath,
                systemDependencies: manifest.systemDependencies,
                programInterpreter: manifest.programInterpreter
            )
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                manifestDigest: try container.decode(
                    String.self,
                    forKey: .manifestDigest
                ),
                receiptDigest: try container.decode(
                    String.self,
                    forKey: .receiptDigest
                ),
                executable: try container.decode(File.self, forKey: .executable),
                libraries: try container.decode([File].self, forKey: .libraries),
                loaderSearchPath: try container.decode(
                    String.self,
                    forKey: .loaderSearchPath
                ),
                systemDependencies: try container.decode(
                    [String].self,
                    forKey: .systemDependencies
                ),
                programInterpreter: try container.decodeIfPresent(
                    String.self,
                    forKey: .programInterpreter
                )
            )
        }

        package func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(manifestDigest, forKey: .manifestDigest)
            try container.encode(receiptDigest, forKey: .receiptDigest)
            try container.encode(executable, forKey: .executable)
            try container.encode(libraries, forKey: .libraries)
            try container.encode(loaderSearchPath, forKey: .loaderSearchPath)
            try container.encode(systemDependencies, forKey: .systemDependencies)
            if let programInterpreter {
                try container.encode(
                    programInterpreter,
                    forKey: .programInterpreter
                )
            } else {
                try container.encodeNil(forKey: .programInterpreter)
            }
        }

        fileprivate var canonicalRecords: [String] {
            var records = [
                "manifest=\(manifestDigest)",
                "receipt=\(receiptDigest)",
                "loader=\(loaderSearchPath)",
                "interpreter=\(programInterpreter ?? "none")",
            ]
            records.append(contentsOf: executable.canonicalRecords.map {
                "executable-\($0)"
            })
            for library in libraries {
                records.append(contentsOf: library.canonicalRecords.map {
                    "library-\($0)"
                })
            }
            records.append(contentsOf: systemDependencies.map {
                "system=\($0)"
            })
            return records
        }
    }

    package struct ArtifactIdentityRecord: Codable, Equatable, Sendable {
        package let targetName: String
        package let moduleName: String
        package let artifactName: String
        package let libraryName: String
        package let symbolPrefix: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case targetName
            case moduleName
            case artifactName
            case libraryName
            case symbolPrefix
        }

        package init(_ identity: MojoArtifactIdentity) {
            self.targetName = identity.targetName
            self.moduleName = identity.moduleName
            self.artifactName = identity.artifactName
            self.libraryName = identity.libraryName
            self.symbolPrefix = identity.symbolPrefix
        }

        package init(
            targetName: String,
            moduleName: String,
            artifactName: String,
            libraryName: String,
            symbolPrefix: String
        ) throws {
            let expected: MojoArtifactIdentity
            do {
                expected = try MojoArtifactIdentity(targetName: targetName)
            } catch {
                throw invalidWorkerBundle(
                    "worker artifact target identity is invalid: \(error)"
                )
            }
            guard moduleName == expected.moduleName,
                  artifactName == expected.artifactName,
                  libraryName == expected.libraryName,
                  symbolPrefix == expected.symbolPrefix else {
                throw invalidWorkerBundle(
                    "worker artifact identity fields are inconsistent"
                )
            }
            self.targetName = targetName
            self.moduleName = moduleName
            self.artifactName = artifactName
            self.libraryName = libraryName
            self.symbolPrefix = symbolPrefix
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                targetName: try container.decode(String.self, forKey: .targetName),
                moduleName: try container.decode(String.self, forKey: .moduleName),
                artifactName: try container.decode(
                    String.self,
                    forKey: .artifactName
                ),
                libraryName: try container.decode(
                    String.self,
                    forKey: .libraryName
                ),
                symbolPrefix: try container.decode(
                    String.self,
                    forKey: .symbolPrefix
                )
            )
        }

        fileprivate var canonicalRecords: [String] {
            [
                "target-name=\(targetName)",
                "module-name=\(moduleName)",
                "artifact-name=\(artifactName)",
                "library-name=\(libraryName)",
                "symbol-prefix=\(symbolPrefix)",
            ]
        }
    }

    package struct TargetClosure: Codable, Equatable, Sendable {
        package let targetTriple: String
        package let targetCPU: String
        package let targetAccelerator: String
        package let artifactIdentity: ArtifactIdentityRecord
        package let targetClosureDigest: String

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case targetTriple
            case targetCPU
            case targetAccelerator
            case artifactIdentity
            case targetClosureDigest
        }

        package init(
            target: MojoTargetConfiguration,
            artifactIdentity: MojoArtifactIdentity,
            targetClosureDigest: String
        ) throws {
            guard let accelerator = target.accelerator else {
                throw invalidWorkerBundle(
                    "worker target closure requires an accelerator compile target"
                )
            }
            try self.init(
                targetTriple: target.triple,
                targetCPU: target.cpu,
                targetAccelerator: accelerator,
                artifactIdentity: ArtifactIdentityRecord(artifactIdentity),
                targetClosureDigest: targetClosureDigest
            )
        }

        package init(
            targetTriple: String,
            targetCPU: String,
            targetAccelerator: String,
            artifactIdentity: ArtifactIdentityRecord,
            targetClosureDigest: String
        ) throws {
            do {
                _ = try MojoTargetConfiguration(
                    triple: targetTriple,
                    cpu: targetCPU,
                    accelerator: targetAccelerator
                )
            } catch {
                throw invalidWorkerBundle(
                    "worker target closure identity is invalid: \(error)"
                )
            }
            try requireWorkerBundleDigests([targetClosureDigest])
            self.targetTriple = targetTriple
            self.targetCPU = targetCPU
            self.targetAccelerator = targetAccelerator
            self.artifactIdentity = artifactIdentity
            self.targetClosureDigest = targetClosureDigest
        }

        package init(from decoder: Decoder) throws {
            try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                targetTriple: try container.decode(
                    String.self,
                    forKey: .targetTriple
                ),
                targetCPU: try container.decode(String.self, forKey: .targetCPU),
                targetAccelerator: try container.decode(
                    String.self,
                    forKey: .targetAccelerator
                ),
                artifactIdentity: try container.decode(
                    ArtifactIdentityRecord.self,
                    forKey: .artifactIdentity
                ),
                targetClosureDigest: try container.decode(
                    String.self,
                    forKey: .targetClosureDigest
                )
            )
        }

        package var target: MojoTargetConfiguration {
            get throws {
                try MojoTargetConfiguration(
                    triple: targetTriple,
                    cpu: targetCPU,
                    accelerator: targetAccelerator
                )
            }
        }

        fileprivate var identityCanonicalRecords: [String] {
            [
                "target-triple=\(targetTriple)",
                "target-cpu=\(targetCPU)",
                "target-accelerator=\(targetAccelerator)",
            ] + artifactIdentity.canonicalRecords
        }
    }

    package static let currentSchemaVersion = 1
    package static let fileName = "RuntimeWorkerBundle.json"

    package let schemaVersion: Int
    package let semanticIdentity: SemanticIdentity
    package let generatedInputs: GeneratedInputs
    package let protocolRecord: ProtocolRecord
    package let runtimeBundle: RuntimeBundleRecord
    package let targetClosure: TargetClosure
    package let executionContractDigest: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case semanticIdentity
        case generatedInputs
        case protocolRecord = "protocol"
        case runtimeBundle
        case targetClosure
        case executionContractDigest
    }

    package init(
        semanticIdentity: SemanticIdentity,
        generatedInputs: GeneratedInputs,
        protocolRecord: ProtocolRecord,
        runtimeBundle: RuntimeBundleRecord,
        targetClosure: TargetClosure,
        executionContractDigest: String
    ) throws {
        try requireWorkerBundleDigests([executionContractDigest])
        guard semanticIdentity.protocolVersion == protocolRecord.version else {
            throw invalidWorkerBundle(
                "semantic and wire protocol versions do not match"
            )
        }
        let expectedTargetClosureDigest = Self.targetClosureDigest(
            semanticIdentity: semanticIdentity,
            generatedInputs: generatedInputs,
            runtimeBundle: runtimeBundle,
            targetClosure: targetClosure,
            executionContractDigest: executionContractDigest
        )
        guard targetClosure.targetClosureDigest
                == expectedTargetClosureDigest else {
            throw invalidWorkerBundle(
                "target closure digest is inconsistent"
            )
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.semanticIdentity = semanticIdentity
        self.generatedInputs = generatedInputs
        self.protocolRecord = protocolRecord
        self.runtimeBundle = runtimeBundle
        self.targetClosure = targetClosure
        self.executionContractDigest = executionContractDigest
    }

    package init(from decoder: Decoder) throws {
        try requireExactWorkerBundleKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw invalidWorkerBundle(
                "unsupported runtime worker schema version \(schemaVersion)"
            )
        }
        try self.init(
            semanticIdentity: try container.decode(
                SemanticIdentity.self,
                forKey: .semanticIdentity
            ),
            generatedInputs: try container.decode(
                GeneratedInputs.self,
                forKey: .generatedInputs
            ),
            protocolRecord: try container.decode(
                ProtocolRecord.self,
                forKey: .protocolRecord
            ),
            runtimeBundle: try container.decode(
                RuntimeBundleRecord.self,
                forKey: .runtimeBundle
            ),
            targetClosure: try container.decode(
                TargetClosure.self,
                forKey: .targetClosure
            ),
            executionContractDigest: try container.decode(
                String.self,
                forKey: .executionContractDigest
            )
        )
    }

    package var digest: String {
        workerBundleDigest(canonicalRecords)
    }

    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    package static func decode(_ data: Data) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: data)
        } catch let error as MojoArtifactError {
            throw error
        } catch {
            throw invalidWorkerBundle(String(describing: error))
        }
    }

    package static func targetClosureDigest(
        semanticIdentity: SemanticIdentity,
        generatedInputs: GeneratedInputs,
        runtimeBundle: RuntimeBundleRecord,
        target: MojoTargetConfiguration,
        artifactIdentity: MojoArtifactIdentity,
        executionContractDigest: String
    ) throws -> String {
        guard let accelerator = target.accelerator else {
            throw invalidWorkerBundle(
                "worker target closure requires an accelerator compile target"
            )
        }
        try requireWorkerBundleDigests([executionContractDigest])
        let identityRecords = [
            "target-triple=\(target.triple)",
            "target-cpu=\(target.cpu)",
            "target-accelerator=\(accelerator)",
        ] + ArtifactIdentityRecord(artifactIdentity).canonicalRecords
        return workerBundleDigest(
            ["target-closure-v1"]
                + semanticIdentity.canonicalRecords
                + generatedInputs.canonicalRecords
                + runtimeBundle.canonicalRecords
                + identityRecords
                + ["execution-contract=\(executionContractDigest)"]
        )
    }

    private static func targetClosureDigest(
        semanticIdentity: SemanticIdentity,
        generatedInputs: GeneratedInputs,
        runtimeBundle: RuntimeBundleRecord,
        targetClosure: TargetClosure,
        executionContractDigest: String
    ) -> String {
        workerBundleDigest(
            ["target-closure-v1"]
                + semanticIdentity.canonicalRecords
                + generatedInputs.canonicalRecords
                + runtimeBundle.canonicalRecords
                + targetClosure.identityCanonicalRecords
                + ["execution-contract=\(executionContractDigest)"]
        )
    }

    private var canonicalRecords: [String] {
        var records = ["schema=\(schemaVersion)"]
        records.append(contentsOf: semanticIdentity.canonicalRecords.map {
            "semantic-\($0)"
        })
        records.append(contentsOf: generatedInputs.canonicalRecords.map {
            "generated-\($0)"
        })
        records.append(contentsOf: protocolRecord.canonicalRecords.map {
            "protocol-\($0)"
        })
        records.append(contentsOf: runtimeBundle.canonicalRecords.map {
            "runtime-\($0)"
        })
        records.append(contentsOf: targetClosure.identityCanonicalRecords.map {
            "target-\($0)"
        })
        records.append("target-closure-digest=\(targetClosure.targetClosureDigest)")
        records.append("execution-contract=\(executionContractDigest)")
        return records
    }
}

private struct WorkerBundleCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private func requireExactWorkerBundleKeys<Key>(
    _ keyType: Key.Type,
    from decoder: Decoder
) throws where Key: CodingKey & CaseIterable {
    let container = try decoder.container(keyedBy: WorkerBundleCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    let expected = Set(Key.allCases.map(\.stringValue))
    guard actual == expected else {
        let missing = expected.subtracting(actual).sorted()
        let unknown = actual.subtracting(expected).sorted()
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription:
                    "closed record key mismatch; missing=\(missing), unknown=\(unknown)"
            )
        )
    }
}

private func invalidWorkerBundle(_ detail: String) -> MojoArtifactError {
    .invalidRuntimeBundle(detail)
}

private func requireWorkerBundleDigests(_ digests: [String]) throws {
    for digest in digests where !isWorkerBundleDigest(digest) {
        throw invalidWorkerBundle(
            "digest '\(digest)' is not a lowercase SHA-256 value"
        )
    }
}

private func isWorkerBundleDigest(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

private func isWorkerBundleRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty,
          !value.hasPrefix("/"),
          !value.contains("\\") else {
        return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func isStrictlySortedWorkerBundleFiles(
    _ files: [MojoRuntimeWorkerBundleManifest.File]
) -> Bool {
    zip(files, files.dropFirst()).allSatisfy {
        $0.relativePath < $1.relativePath
    }
}

private func isStrictlySortedWorkerBundleStrings(_ values: [String]) -> Bool {
    guard values.allSatisfy({ !$0.isEmpty }) else {
        return false
    }
    return zip(values, values.dropFirst()).allSatisfy(<)
}

private func workerBundleDigest(_ records: [String]) -> String {
    var data = Data()
    for record in records {
        var byteCount = UInt64(record.utf8.count).littleEndian
        withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
        data.append(contentsOf: record.utf8)
    }
    return MojoCanonicalDigest.hex(data)
}
