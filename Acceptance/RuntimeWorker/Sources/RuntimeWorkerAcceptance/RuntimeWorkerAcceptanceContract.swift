import Foundation
import MojoRuntime

/// The closed schema-1 receipt for an actual-host worker process/protocol run.
public struct RuntimeWorkerAcceptanceContract: Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let evidenceScopeValue = "actualHostProcessProtocol"

    public enum Status: String, Codable, Equatable, Sendable {
        case passed
        case failed
    }

    public enum EvidenceScope: String, Codable, Equatable, Sendable {
        case actualHostProcessProtocol
    }

    public enum Platform: String, Codable, Equatable, Sendable {
        case macOS
        case linux
    }

    public enum FailureCode: String, Codable, Equatable, Sendable {
        case artifactProjectionInvalid
        case protocolInvalid
        case hostObservationMissing
        case protocolObservationMissing
        case lifecycleIncomplete
        case consumerBoundaryViolation
        case executionEnvironmentViolation
        case invocationTimedOut
        case partialOutputRejected
        case processReapFailed
        case cleanNextAttemptFailed
        case unexpectedFailure
    }

    public enum BindingSignature: String, Codable, Equatable, Hashable,
        Sendable
    {
        case int32Binary
        case borrowedFloat32Buffer
        case borrowedMutableFloat32Buffers
        case borrowedMutableFloat64Buffers
        case runtimeSessionFactory
        case sessionFloat32BufferFactory
        case sessionBorrowedMutableFloat32Buffers
    }

    public struct Claims: Codable, Equatable, Sendable {
        public let actualHostProcess: Bool
        public let protocolLifecycle: Bool
        public let maxDevice: Bool
        public let kernel: Bool
        public let training: Bool
        public let performance: Bool
        public let physicalHIL: Bool

        public init(
            actualHostProcess: Bool,
            protocolLifecycle: Bool,
            maxDevice: Bool = false,
            kernel: Bool = false,
            training: Bool = false,
            performance: Bool = false,
            physicalHIL: Bool = false
        ) throws {
            guard !maxDevice, !kernel, !training, !performance, !physicalHIL
            else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "device, kernel, training, performance, and physical HIL claims must be false"
                )
            }
            self.actualHostProcess = actualHostProcess
            self.protocolLifecycle = protocolLifecycle
            self.maxDevice = maxDevice
            self.kernel = kernel
            self.training = training
            self.performance = performance
            self.physicalHIL = physicalHIL
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case actualHostProcess
            case protocolLifecycle
            case maxDevice
            case kernel
            case training
            case performance
            case physicalHIL
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                actualHostProcess: container.decode(
                    Bool.self,
                    forKey: .actualHostProcess
                ),
                protocolLifecycle: container.decode(
                    Bool.self,
                    forKey: .protocolLifecycle
                ),
                maxDevice: container.decode(Bool.self, forKey: .maxDevice),
                kernel: container.decode(Bool.self, forKey: .kernel),
                training: container.decode(Bool.self, forKey: .training),
                performance: container.decode(
                    Bool.self,
                    forKey: .performance
                ),
                physicalHIL: container.decode(Bool.self, forKey: .physicalHIL)
            )
        }

        fileprivate func validate() throws {
            guard !maxDevice, !kernel, !training, !performance, !physicalHIL
            else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "forbidden claim is true"
                )
            }
        }
    }

    public struct Host: Codable, Equatable, Sendable {
        public let platform: Platform
        public let architecture: String
        public let targetTriple: String
        public let cpu: String
        public let nativeTargetObserved: Bool
        public let processLaunchObserved: Bool
        public let protocolExchangeObserved: Bool

        public init(
            platform: Platform,
            architecture: String,
            targetTriple: String,
            cpu: String,
            nativeTargetObserved: Bool,
            processLaunchObserved: Bool,
            protocolExchangeObserved: Bool
        ) throws {
            guard !architecture.isEmpty,
                  architecture.utf8.count <= 256,
                  !targetTriple.isEmpty,
                  targetTriple.utf8.count <= 512,
                  !cpu.isEmpty,
                  cpu.utf8.count <= 512 else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host identity is empty or exceeds its bound"
                )
            }
            guard (platform == .macOS && architecture == "arm64")
                || (platform == .linux && architecture == "aarch64") else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host architecture is not the accepted native architecture"
                )
            }
            guard isAcceptedNativeTarget(
                platform: platform,
                architecture: architecture,
                targetTriple: targetTriple
            ) else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host target triple is not an accepted native target"
                )
            }
            guard !processLaunchObserved || nativeTargetObserved,
                  !protocolExchangeObserved || processLaunchObserved else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host observations must follow native target then process then protocol order"
                )
            }
            self.platform = platform
            self.architecture = architecture
            self.targetTriple = targetTriple
            self.cpu = cpu
            self.nativeTargetObserved = nativeTargetObserved
            self.processLaunchObserved = processLaunchObserved
            self.protocolExchangeObserved = protocolExchangeObserved
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case platform
            case architecture
            case targetTriple
            case cpu
            case nativeTargetObserved
            case processLaunchObserved
            case protocolExchangeObserved
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                platform: container.decode(Platform.self, forKey: .platform),
                architecture: container.decode(
                    String.self,
                    forKey: .architecture
                ),
                targetTriple: container.decode(
                    String.self,
                    forKey: .targetTriple
                ),
                cpu: container.decode(String.self, forKey: .cpu),
                nativeTargetObserved: container.decode(
                    Bool.self,
                    forKey: .nativeTargetObserved
                ),
                processLaunchObserved: container.decode(
                    Bool.self,
                    forKey: .processLaunchObserved
                ),
                protocolExchangeObserved: container.decode(
                    Bool.self,
                    forKey: .protocolExchangeObserved
                )
            )
        }

        fileprivate func validate(
            as artifact: Artifact.TargetClosure
        ) throws {
            guard targetTriple == artifact.targetTriple,
                  cpu == artifact.targetCPU else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host target identity differs from the artifact target closure"
                )
            }
            guard (platform == .macOS && architecture == "arm64")
                || (platform == .linux && architecture == "aarch64") else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host architecture is not native"
                )
            }
            guard isAcceptedNativeTarget(
                platform: platform,
                architecture: architecture,
                targetTriple: targetTriple
            ) else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host target triple is not native for the declared platform"
                )
            }
            guard !processLaunchObserved || nativeTargetObserved,
                  !protocolExchangeObserved || processLaunchObserved else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "host observations are not causally ordered"
                )
            }
        }

        fileprivate var hasActualProcessObservation: Bool {
            nativeTargetObserved && processLaunchObserved
        }

        fileprivate var hasActualProtocolObservation: Bool {
            protocolExchangeObserved
        }
    }

    public struct Artifact: Codable, Equatable, Sendable {
        public struct Binding: Codable, Equatable, Sendable {
            public let bindingID: UInt64
            public let functionName: String
            public let signature: BindingSignature
            public let sessionFactoryFunctionName: String?

            public init(
                bindingID: UInt64,
                functionName: String,
                signature: BindingSignature,
                sessionFactoryFunctionName: String?
            ) throws {
                guard bindingID > 0,
                      !functionName.isEmpty,
                      functionName.utf8.count <= 4_096 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "binding identity is empty, zero, or exceeds its bound"
                    )
                }
                if let sessionFactoryFunctionName {
                    guard !sessionFactoryFunctionName.isEmpty,
                          sessionFactoryFunctionName.utf8.count <= 4_096 else {
                        throw RuntimeWorkerAcceptanceError.invalidContract(
                            "session factory relationship is empty or exceeds its bound"
                        )
                    }
                }
                switch signature {
                case .runtimeSessionFactory:
                    guard sessionFactoryFunctionName == nil else {
                        throw RuntimeWorkerAcceptanceError.invalidContract(
                            "a session factory cannot reference another factory"
                        )
                    }
                case .sessionFloat32BufferFactory,
                     .sessionBorrowedMutableFloat32Buffers:
                    guard sessionFactoryFunctionName != nil else {
                        throw RuntimeWorkerAcceptanceError.invalidContract(
                            "a session-bound binding requires a factory relationship"
                        )
                    }
                case .int32Binary,
                     .borrowedFloat32Buffer,
                     .borrowedMutableFloat32Buffers,
                     .borrowedMutableFloat64Buffers:
                    guard sessionFactoryFunctionName == nil else {
                        throw RuntimeWorkerAcceptanceError.invalidContract(
                            "a standalone binding cannot reference a session factory"
                        )
                    }
                }
                self.bindingID = bindingID
                self.functionName = functionName
                self.signature = signature
                self.sessionFactoryFunctionName = sessionFactoryFunctionName
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case bindingID
                case functionName
                case signature
                case sessionFactoryFunctionName
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    bindingID: container.decode(
                        UInt64.self,
                        forKey: .bindingID
                    ),
                    functionName: container.decode(
                        String.self,
                        forKey: .functionName
                    ),
                    signature: container.decode(
                        BindingSignature.self,
                        forKey: .signature
                    ),
                    sessionFactoryFunctionName: container.decodeIfPresent(
                        String.self,
                        forKey: .sessionFactoryFunctionName
                    )
                )
            }

            public func encode(to encoder: Encoder) throws {
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
        }

        public struct SemanticIdentity: Codable, Equatable, Sendable {
            public let workerABIVersion: UInt32
            public let protocolVersion: UInt16
            public let sourceGraphDigest: String
            public let sourceGraphIdentifier: UInt64
            public let inputGraphDigest: String
            public let inputGraphIdentifier: UInt64
            public let generationPipelineDigest: String
            public let bindingTableDigest: String
            public let bindings: [Binding]

            public init(
                workerABIVersion: UInt32,
                protocolVersion: UInt16,
                sourceGraphDigest: String,
                sourceGraphIdentifier: UInt64,
                inputGraphDigest: String,
                inputGraphIdentifier: UInt64,
                generationPipelineDigest: String,
                bindingTableDigest: String,
                bindings: [Binding]
            ) throws {
                guard workerABIVersion > 0, protocolVersion > 0 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "worker ABI and protocol versions must be positive"
                    )
                }
                try requireDigests([
                    sourceGraphDigest,
                    inputGraphDigest,
                    generationPipelineDigest,
                    bindingTableDigest,
                ])
                guard !bindings.isEmpty,
                      bindings.count <= maximumBindingCount else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "binding table is empty or exceeds its bound"
                    )
                }
                guard bindings == bindings.sorted(by: {
                    $0.bindingID < $1.bindingID
                }),
                      Set(bindings.map(\.bindingID)).count == bindings.count else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "bindings must be unique and in canonical binding-ID order"
                    )
                }
                let names = bindings.map { "\($0.functionName)|\($0.signature.rawValue)" }
                guard Set(names).count == names.count else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "bindings must have unique function/signature identities"
                    )
                }
                let factoryNames = Set(
                    bindings.compactMap { binding -> String? in
                        binding.signature == .runtimeSessionFactory
                            ? binding.functionName
                            : nil
                    }
                )
                guard bindings.allSatisfy({ binding in
                    guard let factory = binding.sessionFactoryFunctionName
                    else {
                        return true
                    }
                    return factoryNames.contains(factory)
                }) else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "session binding references a missing runtime session factory"
                    )
                }
                self.workerABIVersion = workerABIVersion
                self.protocolVersion = protocolVersion
                self.sourceGraphDigest = sourceGraphDigest
                self.sourceGraphIdentifier = sourceGraphIdentifier
                self.inputGraphDigest = inputGraphDigest
                self.inputGraphIdentifier = inputGraphIdentifier
                self.generationPipelineDigest = generationPipelineDigest
                self.bindingTableDigest = bindingTableDigest
                self.bindings = bindings
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case workerABIVersion
                case protocolVersion
                case sourceGraphDigest
                case sourceGraphIdentifier
                case inputGraphDigest
                case inputGraphIdentifier
                case generationPipelineDigest
                case bindingTableDigest
                case bindings
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    workerABIVersion: container.decode(
                        UInt32.self,
                        forKey: .workerABIVersion
                    ),
                    protocolVersion: container.decode(
                        UInt16.self,
                        forKey: .protocolVersion
                    ),
                    sourceGraphDigest: container.decode(
                        String.self,
                        forKey: .sourceGraphDigest
                    ),
                    sourceGraphIdentifier: container.decode(
                        UInt64.self,
                        forKey: .sourceGraphIdentifier
                    ),
                    inputGraphDigest: container.decode(
                        String.self,
                        forKey: .inputGraphDigest
                    ),
                    inputGraphIdentifier: container.decode(
                        UInt64.self,
                        forKey: .inputGraphIdentifier
                    ),
                    generationPipelineDigest: container.decode(
                        String.self,
                        forKey: .generationPipelineDigest
                    ),
                    bindingTableDigest: container.decode(
                        String.self,
                        forKey: .bindingTableDigest
                    ),
                    bindings: container.decode(
                        [Binding].self,
                        forKey: .bindings
                    )
                )
            }

        }

        public struct GeneratedInputs: Codable, Equatable, Sendable {
            public let generatedMojoSourceDigest: String
            public let generatedCWorkerSourceDigest: String
            public let sourceMapDigest: String
            public let generatedMojoObjectDigest: String
            public let generatedCWorkerObjectDigest: String
            public let compilerVersion: String

            public init(
                generatedMojoSourceDigest: String,
                generatedCWorkerSourceDigest: String,
                sourceMapDigest: String,
                generatedMojoObjectDigest: String,
                generatedCWorkerObjectDigest: String,
                compilerVersion: String
            ) throws {
                try requireDigests([
                    generatedMojoSourceDigest,
                    generatedCWorkerSourceDigest,
                    sourceMapDigest,
                    generatedMojoObjectDigest,
                    generatedCWorkerObjectDigest,
                ])
                guard !compilerVersion.isEmpty,
                      compilerVersion.utf8.count <= 4_096 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "compiler version is empty or exceeds its bound"
                    )
                }
                self.generatedMojoSourceDigest = generatedMojoSourceDigest
                self.generatedCWorkerSourceDigest = generatedCWorkerSourceDigest
                self.sourceMapDigest = sourceMapDigest
                self.generatedMojoObjectDigest = generatedMojoObjectDigest
                self.generatedCWorkerObjectDigest = generatedCWorkerObjectDigest
                self.compilerVersion = compilerVersion
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case generatedMojoSourceDigest
                case generatedCWorkerSourceDigest
                case sourceMapDigest
                case generatedMojoObjectDigest
                case generatedCWorkerObjectDigest
                case compilerVersion
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    generatedMojoSourceDigest: container.decode(
                        String.self,
                        forKey: .generatedMojoSourceDigest
                    ),
                    generatedCWorkerSourceDigest: container.decode(
                        String.self,
                        forKey: .generatedCWorkerSourceDigest
                    ),
                    sourceMapDigest: container.decode(
                        String.self,
                        forKey: .sourceMapDigest
                    ),
                    generatedMojoObjectDigest: container.decode(
                        String.self,
                        forKey: .generatedMojoObjectDigest
                    ),
                    generatedCWorkerObjectDigest: container.decode(
                        String.self,
                        forKey: .generatedCWorkerObjectDigest
                    ),
                    compilerVersion: container.decode(
                        String.self,
                        forKey: .compilerVersion
                    )
                )
            }
        }

        public struct File: Codable, Equatable, Sendable {
            public let relativePath: String
            public let sha256Digest: String

            public init(relativePath: String, sha256Digest: String) throws {
                guard relativePath.utf8.count <= maximumPathLength,
                      isNormalizedRelativePath(relativePath) else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "file path is not a normalized relative path"
                    )
                }
                try requireDigests([sha256Digest])
                self.relativePath = relativePath
                self.sha256Digest = sha256Digest
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case relativePath
                case sha256Digest
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    relativePath: container.decode(
                        String.self,
                        forKey: .relativePath
                    ),
                    sha256Digest: container.decode(
                        String.self,
                        forKey: .sha256Digest
                    )
                )
            }
        }

        public struct RuntimeBundle: Codable, Equatable, Sendable {
            public let manifestDigest: String
            public let receiptDigest: String
            public let executable: File
            public let libraries: [File]
            public let loaderSearchPath: String
            public let systemDependencies: [String]
            public let programInterpreter: String?

            public init(
                manifestDigest: String,
                receiptDigest: String,
                executable: File,
                libraries: [File],
                loaderSearchPath: String,
                systemDependencies: [String],
                programInterpreter: String?
            ) throws {
                try requireDigests([manifestDigest, receiptDigest])
                guard !loaderSearchPath.isEmpty,
                      loaderSearchPath.utf8.count <= 4_096 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "loader search path is empty or exceeds its bound"
                    )
                }
                guard libraries == libraries.sorted(by: {
                        $0.relativePath < $1.relativePath
                    }),
                      libraries.count <= maximumLibraryCount,
                      Set(libraries.map(\.relativePath)).count == libraries.count,
                      !libraries.contains(where: {
                          $0.relativePath == executable.relativePath
                      }) else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "runtime libraries are not canonical or overlap the executable"
                    )
                }
                guard systemDependencies.count <= maximumDependencyCount,
                      systemDependencies == systemDependencies.sorted(),
                      Set(systemDependencies).count == systemDependencies.count,
                      systemDependencies.allSatisfy({
                          !$0.isEmpty && $0.utf8.count <= maximumPathLength
                      }) else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "system dependencies are not canonical"
                    )
                }
                guard programInterpreter?.isEmpty != true,
                      (programInterpreter?.utf8.count ?? 0) <= 4_096 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "program interpreter is empty or exceeds its bound"
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

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case manifestDigest
                case receiptDigest
                case executable
                case libraries
                case loaderSearchPath
                case systemDependencies
                case programInterpreter
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    manifestDigest: container.decode(
                        String.self,
                        forKey: .manifestDigest
                    ),
                    receiptDigest: container.decode(
                        String.self,
                        forKey: .receiptDigest
                    ),
                    executable: container.decode(
                        File.self,
                        forKey: .executable
                    ),
                    libraries: container.decode(
                        [File].self,
                        forKey: .libraries
                    ),
                    loaderSearchPath: container.decode(
                        String.self,
                        forKey: .loaderSearchPath
                    ),
                    systemDependencies: container.decode(
                        [String].self,
                        forKey: .systemDependencies
                    ),
                    programInterpreter: container.decodeIfPresent(
                        String.self,
                        forKey: .programInterpreter
                    )
                )
            }

            public func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(manifestDigest, forKey: .manifestDigest)
                try container.encode(receiptDigest, forKey: .receiptDigest)
                try container.encode(executable, forKey: .executable)
                try container.encode(libraries, forKey: .libraries)
                try container.encode(loaderSearchPath, forKey: .loaderSearchPath)
                try container.encode(
                    systemDependencies,
                    forKey: .systemDependencies
                )
                if let programInterpreter {
                    try container.encode(
                        programInterpreter,
                        forKey: .programInterpreter
                    )
                } else {
                    try container.encodeNil(forKey: .programInterpreter)
                }
            }
        }

        public struct ArtifactIdentity: Codable, Equatable, Sendable {
            public let targetName: String
            public let moduleName: String
            public let artifactName: String
            public let libraryName: String
            public let symbolPrefix: String

            public init(
                targetName: String,
                moduleName: String,
                artifactName: String,
                libraryName: String,
                symbolPrefix: String
            ) throws {
                let values = [
                    targetName,
                    moduleName,
                    artifactName,
                    libraryName,
                    symbolPrefix,
                ]
                guard values.allSatisfy({
                    !$0.isEmpty && $0.utf8.count <= 4_096
                }) else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "artifact identity contains an empty or oversized value"
                    )
                }
                self.targetName = targetName
                self.moduleName = moduleName
                self.artifactName = artifactName
                self.libraryName = libraryName
                self.symbolPrefix = symbolPrefix
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case targetName
                case moduleName
                case artifactName
                case libraryName
                case symbolPrefix
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    targetName: container.decode(
                        String.self,
                        forKey: .targetName
                    ),
                    moduleName: container.decode(
                        String.self,
                        forKey: .moduleName
                    ),
                    artifactName: container.decode(
                        String.self,
                        forKey: .artifactName
                    ),
                    libraryName: container.decode(
                        String.self,
                        forKey: .libraryName
                    ),
                    symbolPrefix: container.decode(
                        String.self,
                        forKey: .symbolPrefix
                    )
                )
            }
        }

        public struct TargetClosure: Codable, Equatable, Sendable {
            public let targetTriple: String
            public let targetCPU: String
            public let targetAccelerator: String
            public let artifactIdentity: ArtifactIdentity
            public let targetClosureDigest: String

            public init(
                targetTriple: String,
                targetCPU: String,
                targetAccelerator: String,
                artifactIdentity: ArtifactIdentity,
                targetClosureDigest: String
            ) throws {
                guard !targetTriple.isEmpty,
                      targetTriple.utf8.count <= 512,
                      !targetCPU.isEmpty,
                      targetCPU.utf8.count <= 512,
                      !targetAccelerator.isEmpty,
                      targetAccelerator.utf8.count <= 512 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "target closure identity is empty or exceeds its bound"
                    )
                }
                try requireDigests([targetClosureDigest])
                self.targetTriple = targetTriple
                self.targetCPU = targetCPU
                self.targetAccelerator = targetAccelerator
                self.artifactIdentity = artifactIdentity
                self.targetClosureDigest = targetClosureDigest
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case targetTriple
                case targetCPU
                case targetAccelerator
                case artifactIdentity
                case targetClosureDigest
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    targetTriple: container.decode(
                        String.self,
                        forKey: .targetTriple
                    ),
                    targetCPU: container.decode(
                        String.self,
                        forKey: .targetCPU
                    ),
                    targetAccelerator: container.decode(
                        String.self,
                        forKey: .targetAccelerator
                    ),
                    artifactIdentity: container.decode(
                        ArtifactIdentity.self,
                        forKey: .artifactIdentity
                    ),
                    targetClosureDigest: container.decode(
                        String.self,
                        forKey: .targetClosureDigest
                    )
                )
            }
        }

        public let schemaVersion: Int
        public let bundleDigest: String
        public let executionContractDigest: String
        public let semanticIdentity: SemanticIdentity
        public let generatedInputs: GeneratedInputs
        public let runtimeBundle: RuntimeBundle
        public let targetClosure: TargetClosure

        public init(
            schemaVersion: Int,
            bundleDigest: String,
            executionContractDigest: String,
            semanticIdentity: SemanticIdentity,
            generatedInputs: GeneratedInputs,
            runtimeBundle: RuntimeBundle,
            targetClosure: TargetClosure
        ) throws {
            guard schemaVersion
                    == RuntimeWorkerAcceptanceContract.currentSchemaVersion
            else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "unsupported artifact schema version (schemaVersion)"
                )
            }
            try requireDigests([bundleDigest, executionContractDigest])
            guard semanticIdentity.protocolVersion > 0 else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "artifact semantic protocol version must be positive"
                )
            }
            self.schemaVersion = schemaVersion
            self.bundleDigest = bundleDigest
            self.executionContractDigest = executionContractDigest
            self.semanticIdentity = semanticIdentity
            self.generatedInputs = generatedInputs
            self.runtimeBundle = runtimeBundle
            self.targetClosure = targetClosure
        }

        /// Creates a lossless receipt projection from a freshly verified W2 value.
        public init(projection: MojoRuntimeWorkerBundleVerification) throws {
            let bindings = try projection.bindings.map { binding in
                guard let signature = BindingSignature(
                    rawValue: binding.signature.rawValue
                ) else {
                    throw RuntimeWorkerAcceptanceError.invalidProjection(
                        "unsupported worker binding signature '\(binding.signature.rawValue)'"
                    )
                }
                return try Binding(
                    bindingID: binding.bindingID,
                    functionName: binding.functionName,
                    signature: signature,
                    sessionFactoryFunctionName: binding
                        .sessionFactoryFunctionName
                )
            }
            self = try Self(
                schemaVersion: projection.schemaVersion,
                bundleDigest: projection.bundleDigest,
                executionContractDigest: projection.executionContractDigest,
                semanticIdentity: SemanticIdentity(
                    workerABIVersion: projection.workerABIVersion,
                    protocolVersion: projection.protocolVersion,
                    sourceGraphDigest: projection.sourceGraphDigest,
                    sourceGraphIdentifier: projection.sourceGraphIdentifier,
                    inputGraphDigest: projection.inputGraphDigest,
                    inputGraphIdentifier: projection.inputGraphIdentifier,
                    generationPipelineDigest: projection.generationPipelineDigest,
                    bindingTableDigest: projection.bindingTableDigest,
                    bindings: bindings
                ),
                generatedInputs: GeneratedInputs(
                    generatedMojoSourceDigest: projection
                        .generatedMojoSourceDigest,
                    generatedCWorkerSourceDigest: projection
                        .generatedCWorkerSourceDigest,
                    sourceMapDigest: projection.sourceMapDigest,
                    generatedMojoObjectDigest: projection
                        .generatedMojoObjectDigest,
                    generatedCWorkerObjectDigest: projection
                        .generatedCWorkerObjectDigest,
                    compilerVersion: projection.compilerVersion
                ),
                runtimeBundle: RuntimeBundle(
                    manifestDigest: projection.runtimeBundleManifestDigest,
                    receiptDigest: projection.runtimeReceiptDigest,
                    executable: try File(
                        relativePath: projection.executable.relativePath,
                        sha256Digest: projection.executable.sha256Digest
                    ),
                    libraries: try projection.libraries.map { file in
                        try File(
                            relativePath: file.relativePath,
                            sha256Digest: file.sha256Digest
                        )
                    },
                    loaderSearchPath: projection.loaderSearchPath,
                    systemDependencies: projection.systemDependencies,
                    programInterpreter: projection.programInterpreter
                ),
                targetClosure: TargetClosure(
                    targetTriple: projection.target.triple,
                    targetCPU: projection.target.cpu,
                    targetAccelerator: try requireAccelerator(
                        projection.target.accelerator
                    ),
                    artifactIdentity: try ArtifactIdentity(
                        targetName: projection.artifactIdentity.targetName,
                        moduleName: projection.artifactIdentity.moduleName,
                        artifactName: projection.artifactIdentity.artifactName,
                        libraryName: projection.artifactIdentity.libraryName,
                        symbolPrefix: projection.artifactIdentity.symbolPrefix
                    ),
                    targetClosureDigest: projection.targetClosureDigest
                )
            )
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion
            case bundleDigest
            case executionContractDigest
            case semanticIdentity
            case generatedInputs
            case runtimeBundle
            case targetClosure
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                schemaVersion: container.decode(
                    Int.self,
                    forKey: .schemaVersion
                ),
                bundleDigest: container.decode(
                    String.self,
                    forKey: .bundleDigest
                ),
                executionContractDigest: container.decode(
                    String.self,
                    forKey: .executionContractDigest
                ),
                semanticIdentity: container.decode(
                    SemanticIdentity.self,
                    forKey: .semanticIdentity
                ),
                generatedInputs: container.decode(
                    GeneratedInputs.self,
                    forKey: .generatedInputs
                ),
                runtimeBundle: container.decode(
                    RuntimeBundle.self,
                    forKey: .runtimeBundle
                ),
                targetClosure: container.decode(
                    TargetClosure.self,
                    forKey: .targetClosure
                    )
                )
            }

        }

    public struct ProtocolRecord: Codable, Equatable, Sendable {
        public struct MessageKind: Codable, Equatable, Sendable {
            public let rawValue: UInt16
            public let name: String

            public init(rawValue: UInt16, name: String) throws {
                guard rawValue > 0,
                      !name.isEmpty,
                      name.utf8.count <= 256 else {
                    throw RuntimeWorkerAcceptanceError.invalidContract(
                        "protocol message kind is empty, zero, or oversized"
                    )
                }
                self.rawValue = rawValue
                self.name = name
            }

            private enum CodingKeys: String, CodingKey, CaseIterable {
                case rawValue
                case name
            }

            public init(from decoder: Decoder) throws {
                try requireExactKeys(CodingKeys.self, from: decoder)
                let container = try decoder.container(keyedBy: CodingKeys.self)
                try self.init(
                    rawValue: container.decode(UInt16.self, forKey: .rawValue),
                    name: container.decode(String.self, forKey: .name)
                )
            }
        }

        public static let expectedMessageKinds: [MessageKind] = {
            let values: [(UInt16, String)] = [
                (1, "ready"),
                (2, "createSession"),
                (3, "sessionCreated"),
                (4, "invokeFloat32"),
                (5, "invocationResult"),
                (6, "shutdownSession"),
                (7, "sessionShutdown"),
                (8, "shutdownWorker"),
                (9, "workerShutdown"),
                (10, "failure"),
            ]
            return values.map { value in
                do {
                    return try MessageKind(rawValue: value.0, name: value.1)
                } catch {
                    preconditionFailure(
                        "canonical protocol message kind is invalid: \(error)"
                    )
                }
            }
        }()

        public let version: UInt16
        public let descriptor: Int32
        public let headerByteCount: Int
        public let byteOrder: String
        public let maximumFramePayloadBytes: UInt64
        public let maximumInFlightRequests: Int
        public let messageKinds: [MessageKind]

        public init(
            version: UInt16,
            descriptor: Int32,
            headerByteCount: Int,
            byteOrder: String,
            maximumFramePayloadBytes: UInt64,
            maximumInFlightRequests: Int,
            messageKinds: [MessageKind]
        ) throws {
            guard version == 1,
                  descriptor == 3,
                  headerByteCount == 32,
                  byteOrder == "little-endian",
                  maximumFramePayloadBytes > 0,
                  maximumFramePayloadBytes <= 16 * 1024 * 1024,
                  maximumInFlightRequests == 1,
                  messageKinds == Self.expectedMessageKinds else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "protocol record is not canonical schema-1 v1"
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

        public init(projection: MojoRuntimeWorkerBundleVerification) throws {
            let kinds = try projection.protocolMessageKinds.map { kind in
                try MessageKind(rawValue: kind.rawValue, name: kind.name)
            }
            try self.init(
                version: projection.protocolVersion,
                descriptor: projection.protocolDescriptor,
                headerByteCount: projection.protocolHeaderByteCount,
                byteOrder: projection.protocolByteOrder,
                maximumFramePayloadBytes: projection.maximumFramePayloadBytes,
                maximumInFlightRequests: projection.maximumInFlightRequests,
                messageKinds: kinds
            )
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case version
            case descriptor
            case headerByteCount
            case byteOrder
            case maximumFramePayloadBytes
            case maximumInFlightRequests
            case messageKinds
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                version: container.decode(UInt16.self, forKey: .version),
                descriptor: container.decode(Int32.self, forKey: .descriptor),
                headerByteCount: container.decode(
                    Int.self,
                    forKey: .headerByteCount
                ),
                byteOrder: container.decode(String.self, forKey: .byteOrder),
                maximumFramePayloadBytes: container.decode(
                    UInt64.self,
                    forKey: .maximumFramePayloadBytes
                ),
                maximumInFlightRequests: container.decode(
                    Int.self,
                    forKey: .maximumInFlightRequests
                ),
                messageKinds: container.decode(
                    [MessageKind].self,
                    forKey: .messageKinds
                )
            )
        }
    }

    public struct ConsumerBoundary: Codable, Equatable, Sendable {
        public let publicRuntimeProjectionUsed: Bool
        public let publicWorkerAPIUsed: Bool
        public let filesystemAccessOutsideWorker: Bool
        public let processLaunchOutsideWorker: Bool
        public let runtimeLoaderOutsideWorker: Bool
        public let rawPOSIXImports: Bool
        public let rawProtocolImports: Bool
        public let workerSPIImports: Bool

        public init(
            publicRuntimeProjectionUsed: Bool,
            publicWorkerAPIUsed: Bool,
            filesystemAccessOutsideWorker: Bool,
            processLaunchOutsideWorker: Bool,
            runtimeLoaderOutsideWorker: Bool,
            rawPOSIXImports: Bool,
            rawProtocolImports: Bool,
            workerSPIImports: Bool
        ) {
            self.publicRuntimeProjectionUsed = publicRuntimeProjectionUsed
            self.publicWorkerAPIUsed = publicWorkerAPIUsed
            self.filesystemAccessOutsideWorker = filesystemAccessOutsideWorker
            self.processLaunchOutsideWorker = processLaunchOutsideWorker
            self.runtimeLoaderOutsideWorker = runtimeLoaderOutsideWorker
            self.rawPOSIXImports = rawPOSIXImports
            self.rawProtocolImports = rawProtocolImports
            self.workerSPIImports = workerSPIImports
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case publicRuntimeProjectionUsed
            case publicWorkerAPIUsed
            case filesystemAccessOutsideWorker
            case processLaunchOutsideWorker
            case runtimeLoaderOutsideWorker
            case rawPOSIXImports
            case rawProtocolImports
            case workerSPIImports
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                publicRuntimeProjectionUsed: try container.decode(
                    Bool.self,
                    forKey: .publicRuntimeProjectionUsed
                ),
                publicWorkerAPIUsed: try container.decode(
                    Bool.self,
                    forKey: .publicWorkerAPIUsed
                ),
                filesystemAccessOutsideWorker: try container.decode(
                    Bool.self,
                    forKey: .filesystemAccessOutsideWorker
                ),
                processLaunchOutsideWorker: try container.decode(
                    Bool.self,
                    forKey: .processLaunchOutsideWorker
                ),
                runtimeLoaderOutsideWorker: try container.decode(
                    Bool.self,
                    forKey: .runtimeLoaderOutsideWorker
                ),
                rawPOSIXImports: try container.decode(
                    Bool.self,
                    forKey: .rawPOSIXImports
                ),
                rawProtocolImports: try container.decode(
                    Bool.self,
                    forKey: .rawProtocolImports
                ),
                workerSPIImports: try container.decode(
                    Bool.self,
                    forKey: .workerSPIImports
                )
            )
        }

        fileprivate func validate() throws {
            guard publicRuntimeProjectionUsed,
                  publicWorkerAPIUsed,
                  !filesystemAccessOutsideWorker,
                  !processLaunchOutsideWorker,
                  !runtimeLoaderOutsideWorker,
                  !rawPOSIXImports,
                  !rawProtocolImports,
                  !workerSPIImports else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "consumer boundary is not public-API-only"
                )
            }
        }
    }

    public struct ExecutionEnvironment: Codable, Equatable, Sendable {
        public let compilerAvailableDuringExecution: Bool
        public let pythonAvailableDuringExecution: Bool
        public let ambientLoaderVariableNames: [String]
        public let cleanEnvironmentObserved: Bool

        public init(
            compilerAvailableDuringExecution: Bool,
            pythonAvailableDuringExecution: Bool,
            ambientLoaderVariableNames: [String],
            cleanEnvironmentObserved: Bool
        ) throws {
            guard ambientLoaderVariableNames == ambientLoaderVariableNames.sorted(),
                  ambientLoaderVariableNames.count <= maximumEnvironmentVariableCount,
                  Set(ambientLoaderVariableNames).count
                    == ambientLoaderVariableNames.count,
                  ambientLoaderVariableNames.allSatisfy({
                      !$0.isEmpty && $0.utf8.count <= 256
                  }) else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "ambient loader variable names are not canonical"
                )
            }
            self.compilerAvailableDuringExecution =
                compilerAvailableDuringExecution
            self.pythonAvailableDuringExecution = pythonAvailableDuringExecution
            self.ambientLoaderVariableNames = ambientLoaderVariableNames
            self.cleanEnvironmentObserved = cleanEnvironmentObserved
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case compilerAvailableDuringExecution
            case pythonAvailableDuringExecution
            case ambientLoaderVariableNames
            case cleanEnvironmentObserved
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                compilerAvailableDuringExecution: container.decode(
                    Bool.self,
                    forKey: .compilerAvailableDuringExecution
                ),
                pythonAvailableDuringExecution: container.decode(
                    Bool.self,
                    forKey: .pythonAvailableDuringExecution
                ),
                ambientLoaderVariableNames: container.decode(
                    [String].self,
                    forKey: .ambientLoaderVariableNames
                ),
                cleanEnvironmentObserved: container.decode(
                    Bool.self,
                    forKey: .cleanEnvironmentObserved
                )
            )
        }

        fileprivate func validate() throws {
            guard !compilerAvailableDuringExecution,
                  !pythonAvailableDuringExecution,
                  ambientLoaderVariableNames.isEmpty,
                  cleanEnvironmentObserved else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "execution environment is not clean"
                )
            }
        }
    }

    public struct Lifecycle: Codable, Equatable, Sendable {
        public let stagingVerificationObserved: Bool
        public let readyAdmissionObserved: Bool
        public let sessionCreationObserved: Bool
        public let nonEmptyInvocationInputElementCount: Int
        public let nonEmptyInvocationOutputElementCount: Int
        public let gracefulShutdownObserved: Bool
        public let forcedFailureObserved: Bool
        public let forcedFailureTimedOut: Bool
        public let forcedFailureProcessGroupReaped: Bool
        public let forcedFailurePartialOutputElementCount: Int
        public let forcedFailureCleanupFailureCount: Int
        public let cleanNextAttemptObserved: Bool

        public init(
            stagingVerificationObserved: Bool,
            readyAdmissionObserved: Bool,
            sessionCreationObserved: Bool,
            nonEmptyInvocationInputElementCount: Int,
            nonEmptyInvocationOutputElementCount: Int,
            gracefulShutdownObserved: Bool,
            forcedFailureObserved: Bool,
            forcedFailureTimedOut: Bool,
            forcedFailureProcessGroupReaped: Bool,
            forcedFailurePartialOutputElementCount: Int,
            forcedFailureCleanupFailureCount: Int,
            cleanNextAttemptObserved: Bool
        ) throws {
            guard nonEmptyInvocationInputElementCount >= 0,
                  nonEmptyInvocationOutputElementCount >= 0,
                  forcedFailurePartialOutputElementCount >= 0,
                  forcedFailureCleanupFailureCount >= 0,
                  nonEmptyInvocationOutputElementCount == 0
                    || nonEmptyInvocationInputElementCount > 0,
                  !forcedFailureTimedOut || forcedFailureObserved,
                  !forcedFailureProcessGroupReaped || forcedFailureObserved,
                  forcedFailurePartialOutputElementCount == 0
                    || forcedFailureObserved,
                  forcedFailureCleanupFailureCount == 0
                    || forcedFailureObserved else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "lifecycle observations are negative or causally inconsistent"
                )
            }
            self.stagingVerificationObserved = stagingVerificationObserved
            self.readyAdmissionObserved = readyAdmissionObserved
            self.sessionCreationObserved = sessionCreationObserved
            self.nonEmptyInvocationInputElementCount =
                nonEmptyInvocationInputElementCount
            self.nonEmptyInvocationOutputElementCount =
                nonEmptyInvocationOutputElementCount
            self.gracefulShutdownObserved = gracefulShutdownObserved
            self.forcedFailureObserved = forcedFailureObserved
            self.forcedFailureTimedOut = forcedFailureTimedOut
            self.forcedFailureProcessGroupReaped = forcedFailureProcessGroupReaped
            self.forcedFailurePartialOutputElementCount =
                forcedFailurePartialOutputElementCount
            self.forcedFailureCleanupFailureCount = forcedFailureCleanupFailureCount
            self.cleanNextAttemptObserved = cleanNextAttemptObserved
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case stagingVerificationObserved
            case readyAdmissionObserved
            case sessionCreationObserved
            case nonEmptyInvocationInputElementCount
            case nonEmptyInvocationOutputElementCount
            case gracefulShutdownObserved
            case forcedFailureObserved
            case forcedFailureTimedOut
            case forcedFailureProcessGroupReaped
            case forcedFailurePartialOutputElementCount
            case forcedFailureCleanupFailureCount
            case cleanNextAttemptObserved
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                stagingVerificationObserved: container.decode(
                    Bool.self,
                    forKey: .stagingVerificationObserved
                ),
                readyAdmissionObserved: container.decode(
                    Bool.self,
                    forKey: .readyAdmissionObserved
                ),
                sessionCreationObserved: container.decode(
                    Bool.self,
                    forKey: .sessionCreationObserved
                ),
                nonEmptyInvocationInputElementCount: container.decode(
                    Int.self,
                    forKey: .nonEmptyInvocationInputElementCount
                ),
                nonEmptyInvocationOutputElementCount: container.decode(
                    Int.self,
                    forKey: .nonEmptyInvocationOutputElementCount
                ),
                gracefulShutdownObserved: container.decode(
                    Bool.self,
                    forKey: .gracefulShutdownObserved
                ),
                forcedFailureObserved: container.decode(
                    Bool.self,
                    forKey: .forcedFailureObserved
                ),
                forcedFailureTimedOut: container.decode(
                    Bool.self,
                    forKey: .forcedFailureTimedOut
                ),
                forcedFailureProcessGroupReaped: container.decode(
                    Bool.self,
                    forKey: .forcedFailureProcessGroupReaped
                ),
                forcedFailurePartialOutputElementCount: container.decode(
                    Int.self,
                    forKey: .forcedFailurePartialOutputElementCount
                ),
                forcedFailureCleanupFailureCount: container.decode(
                    Int.self,
                    forKey: .forcedFailureCleanupFailureCount
                ),
                cleanNextAttemptObserved: container.decode(
                    Bool.self,
                    forKey: .cleanNextAttemptObserved
                )
            )
        }

        fileprivate func validateAsPassed() throws {
            guard stagingVerificationObserved,
                  readyAdmissionObserved,
                  sessionCreationObserved,
                  nonEmptyInvocationInputElementCount > 0,
                  nonEmptyInvocationOutputElementCount > 0,
                  gracefulShutdownObserved,
                  forcedFailureObserved,
                  forcedFailureTimedOut,
                  forcedFailureProcessGroupReaped,
                  forcedFailurePartialOutputElementCount == 0,
                  forcedFailureCleanupFailureCount == 0,
                  cleanNextAttemptObserved else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "passed receipt lacks complete lifecycle observations"
                )
            }
        }
    }

    public struct Failure: Codable, Equatable, Sendable {
        public let code: FailureCode
        public let message: String

        public init(code: FailureCode, message: String) throws {
            guard !message.isEmpty, message.utf8.count <= 4_096 else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "failure message is empty or exceeds its bound"
                )
            }
            self.code = code
            self.message = message
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case code
            case message
        }

        public init(from decoder: Decoder) throws {
            try requireExactKeys(CodingKeys.self, from: decoder)
            let container = try decoder.container(keyedBy: CodingKeys.self)
            try self.init(
                code: container.decode(FailureCode.self, forKey: .code),
                message: container.decode(String.self, forKey: .message)
            )
        }
    }

    public let schemaVersion: Int
    public let status: Status
    public let evidenceScope: EvidenceScope
    public let claims: Claims
    public let swiftMojoRevision: String
    public let acceptanceSourceDigest: String
    public let host: Host
    public let artifact: Artifact
    public let protocolRecord: ProtocolRecord
    public let consumerBoundary: ConsumerBoundary
    public let executionEnvironment: ExecutionEnvironment
    public let lifecycle: Lifecycle
    public let failure: Failure?

    public init(
        status: Status,
        claims: Claims,
        swiftMojoRevision: String,
        acceptanceSourceDigest: String,
        host: Host,
        artifact: Artifact,
        protocolRecord: ProtocolRecord,
        consumerBoundary: ConsumerBoundary,
        executionEnvironment: ExecutionEnvironment,
        lifecycle: Lifecycle,
        failure: Failure?
    ) throws {
        guard swiftMojoRevision.utf8.count == 40
                || swiftMojoRevision.utf8.count == 64,
              isLowercaseHex(swiftMojoRevision),
              swiftMojoRevision.utf8.count <= 64 else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "swift-mojo revision must be a lowercase 40- or 64-character Git object ID"
            )
        }
        try requireDigests([acceptanceSourceDigest])
        try claims.validate()
        try host.validate(as: artifact.targetClosure)
        guard artifact.semanticIdentity.protocolVersion == protocolRecord.version
        else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "semantic and wire protocol versions differ"
            )
        }
        switch status {
        case .passed:
            guard failure == nil else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "a passed receipt cannot contain a failure"
                )
            }
            guard claims.actualHostProcess,
                  claims.protocolLifecycle,
                  host.hasActualProcessObservation,
                  host.hasActualProtocolObservation else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "a passed receipt requires actual host process and protocol observations"
                )
            }
            try consumerBoundary.validate()
            try executionEnvironment.validate()
            try lifecycle.validateAsPassed()
        case .failed:
            guard failure != nil else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "a failed receipt requires a typed failure"
                )
            }
            guard claims.actualHostProcess == host.hasActualProcessObservation,
                  claims.protocolLifecycle == host.hasActualProtocolObservation
            else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "claims do not match host observations"
                )
            }
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.status = status
        self.evidenceScope = .actualHostProcessProtocol
        self.claims = claims
        self.swiftMojoRevision = swiftMojoRevision
        self.acceptanceSourceDigest = acceptanceSourceDigest
        self.host = host
        self.artifact = artifact
        self.protocolRecord = protocolRecord
        self.consumerBoundary = consumerBoundary
        self.executionEnvironment = executionEnvironment
        self.lifecycle = lifecycle
        self.failure = failure
    }

    /// Constructs a receipt while deriving artifact and protocol records from W2.
    public init(
        status: Status,
        claims: Claims,
        swiftMojoRevision: String,
        acceptanceSourceDigest: String,
        host: Host,
        projection: MojoRuntimeWorkerBundleVerification,
        consumerBoundary: ConsumerBoundary,
        executionEnvironment: ExecutionEnvironment,
        lifecycle: Lifecycle,
        failure: Failure?
    ) throws {
        try self.init(
            status: status,
            claims: claims,
            swiftMojoRevision: swiftMojoRevision,
            acceptanceSourceDigest: acceptanceSourceDigest,
            host: host,
            artifact: Artifact(projection: projection),
            protocolRecord: ProtocolRecord(projection: projection),
            consumerBoundary: consumerBoundary,
            executionEnvironment: executionEnvironment,
            lifecycle: lifecycle,
            failure: failure
        )
    }

    /// Returns compact sorted-key JSON and validates the complete contract first.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(RuntimeWorkerAcceptanceWireReceipt(self))
    }

    /// Decodes only the exact canonical bytes emitted by `encoded()`.
    public static func decodeCanonical(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedReceiptBytes else {
            throw RuntimeWorkerAcceptanceError.invalidJSON(
                "receipt exceeds its encoded-size bound"
            )
        }
        let value: Self
        do {
            let wire = try JSONDecoder().decode(
                RuntimeWorkerAcceptanceWireReceipt.self,
                from: data
            )
            value = try wire.contract()
        } catch let error as RuntimeWorkerAcceptanceError {
            throw error
        } catch {
            throw RuntimeWorkerAcceptanceError.invalidJSON(
                String(describing: error)
            )
        }
        let canonical: Data
        do {
            canonical = try value.encoded()
        } catch {
            throw RuntimeWorkerAcceptanceError.invalidJSON(
                String(describing: error)
            )
        }
        guard canonical == data else {
            throw RuntimeWorkerAcceptanceError.nonCanonicalJSON
        }
        return value
    }

    private func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              evidenceScope == .actualHostProcessProtocol else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "receipt schema or evidence scope is not canonical"
            )
        }
        try requireDigests([acceptanceSourceDigest])
        try claims.validate()
        try host.validate(as: artifact.targetClosure)
        guard artifact.semanticIdentity.protocolVersion == protocolRecord.version
        else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "semantic and wire protocol versions differ"
            )
        }
        switch status {
        case .passed:
            guard failure == nil,
                  claims.actualHostProcess,
                  claims.protocolLifecycle,
                  host.hasActualProcessObservation,
                  host.hasActualProtocolObservation else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "passed receipt is missing actual-host evidence"
                )
            }
            try consumerBoundary.validate()
            try executionEnvironment.validate()
            try lifecycle.validateAsPassed()
        case .failed:
            guard failure != nil,
                  claims.actualHostProcess == host.hasActualProcessObservation,
                  claims.protocolLifecycle == host.hasActualProtocolObservation
            else {
                throw RuntimeWorkerAcceptanceError.invalidContract(
                    "failed receipt has no typed failure or inconsistent claims"
                )
            }
        }
    }
}

/// Internal wire representation used by the canonical receipt codec.
///
/// The public receipt intentionally does not conform to Codable. Keeping this
/// DTO private makes `encoded()` and `decodeCanonical(_:)` the only receipt
/// serialization authority exposed to consumers.
private struct RuntimeWorkerAcceptanceWireReceipt: Codable {
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case status
        case evidenceScope
        case claims
        case swiftMojoRevision
        case acceptanceSourceDigest
        case host
        case artifact
        case protocolRecord = "protocol"
        case consumerBoundary
        case executionEnvironment
        case lifecycle
        case failure
    }

    let schemaVersion: Int
    let status: RuntimeWorkerAcceptanceContract.Status
    let evidenceScope: RuntimeWorkerAcceptanceContract.EvidenceScope
    let claims: RuntimeWorkerAcceptanceContract.Claims
    let swiftMojoRevision: String
    let acceptanceSourceDigest: String
    let host: RuntimeWorkerAcceptanceContract.Host
    let artifact: RuntimeWorkerAcceptanceContract.Artifact
    let protocolRecord: RuntimeWorkerAcceptanceContract.ProtocolRecord
    let consumerBoundary: RuntimeWorkerAcceptanceContract.ConsumerBoundary
    let executionEnvironment:
        RuntimeWorkerAcceptanceContract.ExecutionEnvironment
    let lifecycle: RuntimeWorkerAcceptanceContract.Lifecycle
    let failure: RuntimeWorkerAcceptanceContract.Failure?

    init(_ receipt: RuntimeWorkerAcceptanceContract) {
        self.schemaVersion = receipt.schemaVersion
        self.status = receipt.status
        self.evidenceScope = receipt.evidenceScope
        self.claims = receipt.claims
        self.swiftMojoRevision = receipt.swiftMojoRevision
        self.acceptanceSourceDigest = receipt.acceptanceSourceDigest
        self.host = receipt.host
        self.artifact = receipt.artifact
        self.protocolRecord = receipt.protocolRecord
        self.consumerBoundary = receipt.consumerBoundary
        self.executionEnvironment = receipt.executionEnvironment
        self.lifecycle = receipt.lifecycle
        self.failure = receipt.failure
    }

    init(from decoder: Decoder) throws {
        try requireExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(
            Int.self,
            forKey: .schemaVersion
        )
        guard schemaVersion == RuntimeWorkerAcceptanceContract.currentSchemaVersion
        else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "unsupported receipt schema version (schemaVersion)"
            )
        }
        let evidenceScope = try container.decode(
            RuntimeWorkerAcceptanceContract.EvidenceScope.self,
            forKey: .evidenceScope
        )
        guard evidenceScope == .actualHostProcessProtocol else {
            throw RuntimeWorkerAcceptanceError.invalidContract(
                "unsupported receipt evidence scope"
            )
        }
        self.schemaVersion = schemaVersion
        self.status = try container.decode(
            RuntimeWorkerAcceptanceContract.Status.self,
            forKey: .status
        )
        self.evidenceScope = evidenceScope
        self.claims = try container.decode(
            RuntimeWorkerAcceptanceContract.Claims.self,
            forKey: .claims
        )
        self.swiftMojoRevision = try container.decode(
            String.self,
            forKey: .swiftMojoRevision
        )
        self.acceptanceSourceDigest = try container.decode(
            String.self,
            forKey: .acceptanceSourceDigest
        )
        self.host = try container.decode(
            RuntimeWorkerAcceptanceContract.Host.self,
            forKey: .host
        )
        self.artifact = try container.decode(
            RuntimeWorkerAcceptanceContract.Artifact.self,
            forKey: .artifact
        )
        self.protocolRecord = try container.decode(
            RuntimeWorkerAcceptanceContract.ProtocolRecord.self,
            forKey: .protocolRecord
        )
        self.consumerBoundary = try container.decode(
            RuntimeWorkerAcceptanceContract.ConsumerBoundary.self,
            forKey: .consumerBoundary
        )
        self.executionEnvironment = try container.decode(
            RuntimeWorkerAcceptanceContract.ExecutionEnvironment.self,
            forKey: .executionEnvironment
        )
        self.lifecycle = try container.decode(
            RuntimeWorkerAcceptanceContract.Lifecycle.self,
            forKey: .lifecycle
        )
        self.failure = try container.decodeIfPresent(
            RuntimeWorkerAcceptanceContract.Failure.self,
            forKey: .failure
        )
    }

    func contract() throws -> RuntimeWorkerAcceptanceContract {
        try RuntimeWorkerAcceptanceContract(
            status: status,
            claims: claims,
            swiftMojoRevision: swiftMojoRevision,
            acceptanceSourceDigest: acceptanceSourceDigest,
            host: host,
            artifact: artifact,
            protocolRecord: protocolRecord,
            consumerBoundary: consumerBoundary,
            executionEnvironment: executionEnvironment,
            lifecycle: lifecycle,
            failure: failure
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(status, forKey: .status)
        try container.encode(evidenceScope, forKey: .evidenceScope)
        try container.encode(claims, forKey: .claims)
        try container.encode(swiftMojoRevision, forKey: .swiftMojoRevision)
        try container.encode(
            acceptanceSourceDigest,
            forKey: .acceptanceSourceDigest
        )
        try container.encode(host, forKey: .host)
        try container.encode(artifact, forKey: .artifact)
        try container.encode(protocolRecord, forKey: .protocolRecord)
        try container.encode(consumerBoundary, forKey: .consumerBoundary)
        try container.encode(
            executionEnvironment,
            forKey: .executionEnvironment
        )
        try container.encode(lifecycle, forKey: .lifecycle)
        if let failure {
            try container.encode(failure, forKey: .failure)
        } else {
            try container.encodeNil(forKey: .failure)
        }
    }
}

private let maximumEncodedReceiptBytes = 16 * 1024 * 1024
private let maximumBindingCount = 1_024
private let maximumLibraryCount = 256
private let maximumDependencyCount = 256
private let maximumEnvironmentVariableCount = 256
private let maximumPathLength = 4_096

private struct AcceptanceCodingKey: CodingKey {
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

private func requireExactKeys<Key: CodingKey & CaseIterable>(
    _ keyType: Key.Type,
    from decoder: Decoder
) throws {
    let container = try decoder.container(keyedBy: AcceptanceCodingKey.self)
    let actual = Set(container.allKeys.map(\.stringValue))
    let expected = Set(Key.allCases.map(\.stringValue))
    guard actual == expected else {
        let missing = expected.subtracting(actual).sorted()
        let unknown = actual.subtracting(expected).sorted()
        throw RuntimeWorkerAcceptanceError.invalidContract(
            "closed record key mismatch; missing=\(missing), unknown=\(unknown)"
        )
    }
}

private func requireDigests(_ values: [String]) throws {
    guard values.allSatisfy(isLowercaseSHA256) else {
        throw RuntimeWorkerAcceptanceError.invalidContract(
            "digest is not a lowercase SHA-256 value"
        )
    }
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && isLowercaseHex(value)
}

private func isLowercaseHex(_ value: String) -> Bool {
    value.utf8.allSatisfy { byte in
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
    }
}

private func isNormalizedRelativePath(_ value: String) -> Bool {
    guard !value.isEmpty,
          !value.hasPrefix("/"),
          !value.contains("\\") else {
        return false
    }
    return value.split(separator: "/", omittingEmptySubsequences: false)
        .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
}

private func isAcceptedNativeTarget(
    platform: RuntimeWorkerAcceptanceContract.Platform,
    architecture: String,
    targetTriple: String
) -> Bool {
    switch platform {
    case .macOS:
        return architecture == "arm64"
            && targetTriple.hasPrefix("arm64-")
            && targetTriple.contains("-apple-macosx")
    case .linux:
        return architecture == "aarch64"
            && targetTriple.hasPrefix("aarch64-")
            && targetTriple.contains("-linux")
    }
}

private func requireAccelerator(_ value: String?) throws -> String {
    guard let value, !value.isEmpty else {
        throw RuntimeWorkerAcceptanceError.invalidProjection(
            "worker target closure has no accelerator target"
        )
    }
    return value
}
