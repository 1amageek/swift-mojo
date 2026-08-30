import Foundation

package enum MojoRuntimeFailureCode: UInt16, CaseIterable, Codable, Sendable {
    case invalidFrame = 1
    case invalidSequence = 2
    case invalidBinding = 3
    case sessionUnavailable = 4
    case invocationFailed = 5
    case shutdownFailed = 6
    case internalFailure = 7
}

package struct MojoRuntimeReadyPayload: Equatable, Codable, Sendable {
    package static let maximumTextByteCount = 4_096

    package let protocolSchemaDigest: String
    package let executionContractDigest: String
    package let inputGraphDigest: String
    package let inputGraphIdentifier: UInt64
    package let bindingTableDigest: String
    package let abiVersion: UInt32
    package let targetTriple: String
    package let targetCPU: String
    package let targetAccelerator: String?
    package let maximumFramePayloadBytes: UInt64

    package init(
        protocolSchemaDigest: String = MojoRuntimeProtocol.schemaDigest,
        executionContractDigest: String,
        inputGraphDigest: String,
        inputGraphIdentifier: UInt64,
        bindingTableDigest: String,
        abiVersion: UInt32,
        targetTriple: String,
        targetCPU: String,
        targetAccelerator: String?,
        maximumFramePayloadBytes: UInt64
    ) throws {
        for digest in [
            protocolSchemaDigest,
            executionContractDigest,
            inputGraphDigest,
            bindingTableDigest,
        ] {
            guard Self.isDigest(digest) else {
                throw MojoRuntimeProtocolError.invalidDigest(digest)
            }
        }
        guard protocolSchemaDigest == MojoRuntimeProtocol.schemaDigest else {
            throw MojoRuntimeProtocolError.invalidDigest(protocolSchemaDigest)
        }
        let limits = try MojoRuntimeProtocolLimits(
            maximumFramePayloadBytes: maximumFramePayloadBytes
        )
        for text in [targetTriple, targetCPU] {
            guard !text.isEmpty,
                  text.utf8.count <= Self.maximumTextByteCount else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: .ready,
                    reason: "target identity is empty or exceeds its bound"
                )
            }
        }
        if let targetAccelerator {
            guard !targetAccelerator.isEmpty,
                  targetAccelerator.utf8.count <= Self.maximumTextByteCount else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: .ready,
                    reason: "target accelerator identity exceeds its bound"
                )
            }
        }
        self.protocolSchemaDigest = protocolSchemaDigest
        self.executionContractDigest = executionContractDigest
        self.inputGraphDigest = inputGraphDigest
        self.inputGraphIdentifier = inputGraphIdentifier
        self.bindingTableDigest = bindingTableDigest
        self.abiVersion = abiVersion
        self.targetTriple = targetTriple
        self.targetCPU = targetCPU
        self.targetAccelerator = targetAccelerator
        self.maximumFramePayloadBytes = limits.maximumFramePayloadBytes
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

package struct MojoRuntimeCreateSessionPayload: Equatable, Codable, Sendable {
    package static let schemaVersion: UInt32 = 1

    package let bindingID: UInt64
    package let requestSchema: UInt32
    package let requestedDevice: UInt32
    package let requestedOrdinal: UInt32
    package let requiredCapabilities: UInt64

    package init(
        bindingID: UInt64,
        requestSchema: UInt32 = schemaVersion,
        requestedDevice: UInt32,
        requestedOrdinal: UInt32,
        requiredCapabilities: UInt64
    ) throws {
        guard bindingID != 0 else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .createSession,
                reason: "binding identifier is zero"
            )
        }
        guard requestSchema == Self.schemaVersion else {
            throw MojoRuntimeProtocolError.schemaMismatch(
                expected: Self.schemaVersion,
                actual: requestSchema
            )
        }
        self.bindingID = bindingID
        self.requestSchema = requestSchema
        self.requestedDevice = requestedDevice
        self.requestedOrdinal = requestedOrdinal
        self.requiredCapabilities = requiredCapabilities
    }
}

package struct MojoRuntimeSessionCreatedPayload: Equatable, Codable, Sendable {
    package static let schemaVersion =
        MojoRuntimeCreateSessionPayload.schemaVersion

    package let status: Int32
    package let responseSchema: UInt32
    package let actualDevice: UInt32
    package let actualOrdinal: UInt32
    package let availableCapabilities: UInt64

    package init(
        status: Int32,
        responseSchema: UInt32,
        actualDevice: UInt32,
        actualOrdinal: UInt32,
        availableCapabilities: UInt64
    ) throws {
        guard status == 0 else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .sessionCreated,
                reason: "session creation failure must use a failure frame"
            )
        }
        guard responseSchema == Self.schemaVersion else {
            throw MojoRuntimeProtocolError.schemaMismatch(
                expected: Self.schemaVersion,
                actual: responseSchema
            )
        }
        self.status = status
        self.responseSchema = responseSchema
        self.actualDevice = actualDevice
        self.actualOrdinal = actualOrdinal
        self.availableCapabilities = availableCapabilities
    }
}

package struct MojoRuntimeInvokeFloat32Payload: Equatable, Codable, Sendable {
    package let bindingID: UInt64
    package let inputElementCount: UInt64
    package let outputElementCount: UInt64

    package init(
        bindingID: UInt64,
        inputElementCount: UInt64,
        outputElementCount: UInt64 = 0
    ) throws {
        guard bindingID != 0 else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .invokeFloat32,
                reason: "binding identifier is zero"
            )
        }
        let count = try MojoRuntimeCheckedArithmetic.int(
            inputElementCount,
            label: "input element count conversion"
        )
        _ = try MojoRuntimeCheckedArithmetic.multiply(
            count,
            MemoryLayout<Float32>.size,
            label: "input element count times Float32 width"
        )
        let outputCount = try MojoRuntimeCheckedArithmetic.int(
            outputElementCount,
            label: "output element count conversion"
        )
        _ = try MojoRuntimeCheckedArithmetic.multiply(
            outputCount,
            MemoryLayout<Float32>.size,
            label: "output element count times Float32 width"
        )
        self.bindingID = bindingID
        self.inputElementCount = inputElementCount
        self.outputElementCount = outputElementCount
    }
}

package struct MojoRuntimeInvocationResultPayload: Equatable, Codable, Sendable {
    package let status: Int32
    package let resultElementCount: UInt64

    package init(status: Int32, resultElementCount: UInt64) throws {
        if status != 0 && resultElementCount != 0 {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: .invocationResult,
                reason: "failed invocation cannot carry a result body"
            )
        }
        self.status = status
        self.resultElementCount = resultElementCount
    }
}

package struct MojoRuntimeFailurePayload: Equatable, Codable, Sendable {
    package static let maximumDiagnosticByteCount = 4_096

    package let code: MojoRuntimeFailureCode
    package let diagnostic: Data

    package init(
        code: MojoRuntimeFailureCode,
        diagnostic: Data = Data()
    ) throws {
        guard diagnostic.count <= Self.maximumDiagnosticByteCount else {
            throw MojoRuntimeProtocolError.payloadTooLarge(
                length: UInt64(diagnostic.count),
                limit: UInt64(Self.maximumDiagnosticByteCount)
            )
        }
        self.code = code
        self.diagnostic = diagnostic
    }

    package init(
        code: MojoRuntimeFailureCode,
        diagnostic: String
    ) throws {
        try self.init(code: code, diagnostic: Data(diagnostic.utf8))
    }
}

package enum MojoRuntimePayload: Equatable, Sendable {
    case ready(MojoRuntimeReadyPayload)
    case createSession(MojoRuntimeCreateSessionPayload)
    case sessionCreated(MojoRuntimeSessionCreatedPayload)
    case invokeFloat32(MojoRuntimeInvokeFloat32Payload)
    case invocationResult(MojoRuntimeInvocationResultPayload)
    case shutdownSession
    case sessionShutdown
    case shutdownWorker
    case workerShutdown
    case failure(MojoRuntimeFailurePayload)

    package var kind: MojoRuntimeFrameKind {
        switch self {
        case .ready: .ready
        case .createSession: .createSession
        case .sessionCreated: .sessionCreated
        case .invokeFloat32: .invokeFloat32
        case .invocationResult: .invocationResult
        case .shutdownSession: .shutdownSession
        case .sessionShutdown: .sessionShutdown
        case .shutdownWorker: .shutdownWorker
        case .workerShutdown: .workerShutdown
        case .failure: .failure
        }
    }
}
