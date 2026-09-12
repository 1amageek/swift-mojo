import Foundation

package struct MojoRuntimeFrameHeader: Equatable, Sendable {
    package let kind: MojoRuntimeFrameKind
    package let requestID: UInt64
    package let payloadByteCount: UInt64
    package let reserved: UInt64

    package init(
        kind: MojoRuntimeFrameKind,
        requestID: UInt64,
        payloadByteCount: UInt64
    ) throws {
        guard payloadByteCount
                <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes else {
            throw MojoRuntimeProtocolError.payloadTooLarge(
                length: payloadByteCount,
                limit: MojoRuntimeProtocol.hardMaximumFramePayloadBytes
            )
        }
        _ = try MojoRuntimeCheckedArithmetic.int(
            payloadByteCount,
            label: "header payload length conversion"
        )
        guard Self.validRequestIdentifier(kind: kind, requestID: requestID) else {
            throw MojoRuntimeProtocolError.invalidRequestIdentifier(
                kind: kind.rawValue,
                requestID: requestID
            )
        }
        self.kind = kind
        self.requestID = requestID
        self.payloadByteCount = payloadByteCount
        self.reserved = 0
    }

    package func encodedBytes() -> [UInt8] {
        var writer = MojoRuntimeByteWriter(
            reservingCapacity: MojoRuntimeProtocol.headerByteCount
        )
        writer.append(contentsOf: MojoRuntimeProtocol.magicBytes)
        writer.appendUInt16(0)
        writer.appendUInt16(kind.rawValue)
        writer.appendUInt64(requestID)
        writer.appendUInt64(payloadByteCount)
        writer.appendUInt64(reserved)
        return writer.bytes
    }

    package func encodedData() -> Data {
        Data(encodedBytes())
    }

    package static func decode(
        _ data: Data,
        limits: MojoRuntimeProtocolLimits
    ) throws -> Self {
        guard data.count >= MojoRuntimeProtocol.headerByteCount else {
            throw MojoRuntimeProtocolError.truncatedHeader(actual: data.count)
        }
        guard data.count == MojoRuntimeProtocol.headerByteCount else {
            throw MojoRuntimeProtocolError.trailingBytes(
                data.count - MojoRuntimeProtocol.headerByteCount
            )
        }
        var reader = MojoRuntimeByteReader(
            data: Data(data.prefix(MojoRuntimeProtocol.headerByteCount))
        )
        let magic = try reader.readBytes(count: MojoRuntimeProtocol.magicBytes.count)
        guard magic == MojoRuntimeProtocol.magicBytes else {
            throw MojoRuntimeProtocolError.invalidMagic(actual: magic)
        }
        let reserved16 = try reader.readUInt16()
        guard reserved16 == 0 else {
            throw MojoRuntimeProtocolError.reservedFieldNonZero(UInt64(reserved16))
        }
        let rawKind = try reader.readUInt16()
        guard let kind = MojoRuntimeFrameKind(rawValue: rawKind) else {
            throw MojoRuntimeProtocolError.unknownKind(rawKind)
        }
        let requestID = try reader.readUInt64()
        let payloadByteCount = try reader.readUInt64()
        let reserved = try reader.readUInt64()
        guard reserved == 0 else {
            throw MojoRuntimeProtocolError.reservedFieldNonZero(reserved)
        }
        guard Self.validRequestIdentifier(kind: kind, requestID: requestID) else {
            throw MojoRuntimeProtocolError.invalidRequestIdentifier(
                kind: rawKind,
                requestID: requestID
            )
        }
        try limits.validate(payloadByteCount: payloadByteCount)
        _ = try MojoRuntimeCheckedArithmetic.int(
            payloadByteCount,
            label: "payload length conversion"
        )
        return Self(
            uncheckedKind: kind,
            requestID: requestID,
            payloadByteCount: payloadByteCount,
            reserved: reserved
        )
    }

    private init(
        uncheckedKind kind: MojoRuntimeFrameKind,
        requestID: UInt64,
        payloadByteCount: UInt64,
        reserved: UInt64
    ) {
        self.kind = kind
        self.requestID = requestID
        self.payloadByteCount = payloadByteCount
        self.reserved = reserved
    }

    private static func validRequestIdentifier(
        kind: MojoRuntimeFrameKind,
        requestID: UInt64
    ) -> Bool {
        if kind.isStartup {
            return requestID == 0 || kind == .failure
        }
        return requestID != 0
    }
}

package struct MojoRuntimeFramePrefix: Equatable, Sendable {
    package let header: MojoRuntimeFrameHeader
    package let payload: MojoRuntimePayload
    package let bodyByteCount: Int

    package init(
        header: MojoRuntimeFrameHeader,
        payload: MojoRuntimePayload,
        bodyByteCount: Int
    ) {
        self.header = header
        self.payload = payload
        self.bodyByteCount = bodyByteCount
    }
}

package struct MojoRuntimeFrame: Equatable, Sendable {
    package let header: MojoRuntimeFrameHeader
    package let payload: MojoRuntimePayload

    package init(
        requestID: UInt64,
        payload: MojoRuntimePayload,
        limits: MojoRuntimeProtocolLimits
    ) throws {
        let prefix = try Self.encodedPayloadPrefix(payload)
        let bodyByteCount = try Self.float32BodyByteCount(payload)
        let totalByteCount = try MojoRuntimeCheckedArithmetic.add(
            prefix.count,
            bodyByteCount,
            label: "payload prefix and Float32 body length"
        )
        guard UInt64(totalByteCount) <= limits.maximumFramePayloadBytes else {
            throw MojoRuntimeProtocolError.payloadTooLarge(
                length: UInt64(totalByteCount),
                limit: limits.maximumFramePayloadBytes
            )
        }
        self.header = try MojoRuntimeFrameHeader(
            kind: payload.kind,
            requestID: requestID,
            payloadByteCount: UInt64(totalByteCount)
        )
        self.payload = payload
    }

    package func encodedData(
        limits: MojoRuntimeProtocolLimits
    ) throws -> Data {
        let prefix = try Self.encodedPayloadPrefix(payload)
        guard UInt64(prefix.count) == header.payloadByteCount else {
            if payload.kind == .invokeFloat32 || payload.kind == .invocationResult {
                throw MojoRuntimeProtocolError.tensorBodyRequiresBorrowedSegment
            }
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: header.kind,
                reason: "header payload length does not match the body"
            )
        }
        try limits.validate(payloadByteCount: header.payloadByteCount)
        var bytes = header.encodedBytes()
        bytes.append(contentsOf: prefix)
        return Data(bytes)
    }

    package func encodedPrefixData(
        limits: MojoRuntimeProtocolLimits
    ) throws -> Data {
        let prefix = try Self.encodedPayloadPrefix(payload)
        guard UInt64(prefix.count) <= header.payloadByteCount else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: header.kind,
                reason: "payload prefix exceeds declared payload length"
            )
        }
        try limits.validate(payloadByteCount: header.payloadByteCount)
        var bytes = header.encodedBytes()
        bytes.append(contentsOf: prefix)
        return Data(bytes)
    }

    package func encodedBytes(
        limits: MojoRuntimeProtocolLimits
    ) throws -> [UInt8] {
        Array(try encodedData(limits: limits))
    }

    package static func decode(
        _ data: Data,
        limits: MojoRuntimeProtocolLimits
    ) throws -> Self {
        guard data.count >= MojoRuntimeProtocol.headerByteCount else {
            throw MojoRuntimeProtocolError.truncatedHeader(actual: data.count)
        }
        let headerData = Data(data.prefix(MojoRuntimeProtocol.headerByteCount))
        let header = try MojoRuntimeFrameHeader.decode(headerData, limits: limits)
        let payloadLength = try MojoRuntimeCheckedArithmetic.int(
            header.payloadByteCount,
            label: "payload length conversion"
        )
        let frameLength = try MojoRuntimeCheckedArithmetic.add(
            MojoRuntimeProtocol.headerByteCount,
            payloadLength,
            label: "frame length"
        )
        guard data.count >= frameLength else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: frameLength,
                actual: data.count
            )
        }
        guard data.count == frameLength else {
            throw MojoRuntimeProtocolError.trailingBytes(data.count - frameLength)
        }
        let prefixByteCount = try payloadPrefixByteCount(
            for: header.kind,
            payloadLength: payloadLength
        )
        let prefixEnd = try MojoRuntimeCheckedArithmetic.add(
            MojoRuntimeProtocol.headerByteCount,
            prefixByteCount,
            label: "payload prefix offset"
        )
        let prefix = try Self.decodePrefix(
            headerData: headerData,
            payloadPrefixData: Data(
                data[MojoRuntimeProtocol.headerByteCount..<prefixEnd]
            ),
            limits: limits
        )
        return Self(header: prefix.header, payload: prefix.payload)
    }

    package static func decodePrefix(
        headerData: Data,
        payloadPrefixData: Data,
        limits: MojoRuntimeProtocolLimits
    ) throws -> MojoRuntimeFramePrefix {
        let header = try MojoRuntimeFrameHeader.decode(
            headerData,
            limits: limits
        )
        let payloadLength = try MojoRuntimeCheckedArithmetic.int(
            header.payloadByteCount,
            label: "payload length conversion"
        )
        let prefixByteCount = try payloadPrefixByteCount(
            for: header.kind,
            payloadLength: payloadLength
        )
        guard payloadPrefixData.count == prefixByteCount else {
            if payloadPrefixData.count < prefixByteCount {
                throw MojoRuntimeProtocolError.truncatedPayload(
                    expected: prefixByteCount,
                    actual: payloadPrefixData.count
                )
            }
            throw MojoRuntimeProtocolError.trailingBytes(
                payloadPrefixData.count - prefixByteCount
            )
        }
        let bodyByteCount = payloadLength - prefixByteCount
        let bodyByteCountArgument: Int? = switch header.kind {
        case .invokeFloat32, .invocationResult:
            bodyByteCount
        case .ready, .createSession, .sessionCreated, .shutdownSession,
             .sessionShutdown, .shutdownWorker, .workerShutdown, .failure:
            nil
        }
        let payload = try Self.decodePayload(
            kind: header.kind,
            data: payloadPrefixData,
            limits: limits,
            bodyByteCount: bodyByteCountArgument
        )
        return MojoRuntimeFramePrefix(
            header: header,
            payload: payload,
            bodyByteCount: bodyByteCount
        )
    }

    package static func payloadPrefixByteCount(
        for kind: MojoRuntimeFrameKind,
        payloadLength: Int
    ) throws -> Int {
        let fixedByteCount: Int? = switch kind {
        case .invokeFloat32:
            24
        case .invocationResult:
            12
        case .ready, .createSession, .sessionCreated, .shutdownSession,
             .sessionShutdown, .shutdownWorker, .workerShutdown, .failure:
            nil
        }
        guard let fixedByteCount else { return payloadLength }
        guard payloadLength >= fixedByteCount else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: fixedByteCount,
                actual: payloadLength
            )
        }
        return fixedByteCount
    }

    private init(header: MojoRuntimeFrameHeader, payload: MojoRuntimePayload) {
        self.header = header
        self.payload = payload
    }

    private static func encodedPayloadPrefix(
        _ payload: MojoRuntimePayload
    ) throws -> [UInt8] {
        var writer = MojoRuntimeByteWriter()
        switch payload {
        case .ready(let value):
            try writer.appendLengthPrefixedString(
                value.protocolSchemaDigest,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            try writer.appendLengthPrefixedString(
                value.executionContractDigest,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            try writer.appendLengthPrefixedString(
                value.inputGraphDigest,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            writer.appendUInt64(value.inputGraphIdentifier)
            try writer.appendLengthPrefixedString(
                value.bindingTableDigest,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            writer.appendUInt32(value.abiVersion)
            try writer.appendLengthPrefixedString(
                value.targetTriple,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            try writer.appendLengthPrefixedString(
                value.targetCPU,
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            if let targetAccelerator = value.targetAccelerator {
                writer.append(1)
                try writer.appendLengthPrefixedString(
                    targetAccelerator,
                    maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
                )
            } else {
                writer.append(0)
            }
            writer.appendUInt64(value.maximumFramePayloadBytes)
        case .createSession(let value):
            writer.appendUInt64(value.bindingID)
            writer.appendUInt32(value.requestSchema)
            writer.appendUInt32(value.requestedDevice)
            writer.appendUInt32(value.requestedOrdinal)
            writer.appendUInt64(value.requiredCapabilities)
        case .sessionCreated(let value):
            writer.appendInt32(value.status)
            writer.appendUInt32(value.responseSchema)
            writer.appendUInt32(value.actualDevice)
            writer.appendUInt32(value.actualOrdinal)
            writer.appendUInt64(value.availableCapabilities)
        case .invokeFloat32(let value):
            writer.appendUInt64(value.bindingID)
            writer.appendUInt64(value.inputElementCount)
            writer.appendUInt64(value.outputElementCount)
        case .invocationResult(let value):
            writer.appendInt32(value.status)
            writer.appendUInt64(value.resultElementCount)
        case .shutdownSession, .sessionShutdown, .shutdownWorker,
             .workerShutdown:
            break
        case .failure(let value):
            writer.appendUInt16(value.code.rawValue)
            writer.appendUInt16(0)
            writer.appendUInt32(UInt32(value.diagnostic.count))
            writer.append(contentsOf: Array(value.diagnostic))
        }
        return writer.bytes
    }

    private static func float32BodyByteCount(
        _ payload: MojoRuntimePayload
    ) throws -> Int {
        switch payload {
        case .invokeFloat32(let value):
            let count = try MojoRuntimeCheckedArithmetic.int(
                value.inputElementCount,
                label: "input element count conversion"
            )
            return try MojoRuntimeCheckedArithmetic.multiply(
                count,
                MemoryLayout<Float32>.size,
                label: "input element count times Float32 width"
            )
        case .invocationResult(let value):
            let count = try MojoRuntimeCheckedArithmetic.int(
                value.resultElementCount,
                label: "result element count conversion"
            )
            return try MojoRuntimeCheckedArithmetic.multiply(
                count,
                MemoryLayout<Float32>.size,
                label: "result element count times Float32 width"
            )
        case .ready, .createSession, .sessionCreated, .shutdownSession,
             .sessionShutdown, .shutdownWorker, .workerShutdown, .failure:
            return 0
        }
    }

    private static func decodePayload(
        kind: MojoRuntimeFrameKind,
        data: Data,
        limits: MojoRuntimeProtocolLimits,
        bodyByteCount: Int?
    ) throws -> MojoRuntimePayload {
        var reader = MojoRuntimeByteReader(data: data)
        switch kind {
        case .ready:
            let schemaDigest = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let executionDigest = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let graphDigest = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let graphIdentifier = try reader.readUInt64()
            let bindingDigest = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let abiVersion = try reader.readUInt32()
            let triple = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let cpu = try reader.readLengthPrefixedString(
                maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
            )
            let acceleratorFlag = try reader.readUInt8()
            guard acceleratorFlag == 0 || acceleratorFlag == 1 else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "invalid accelerator presence flag"
                )
            }
            let accelerator: String?
            if acceleratorFlag == 1 {
                accelerator = try reader.readLengthPrefixedString(
                    maximumByteCount: MojoRuntimeReadyPayload.maximumTextByteCount
                )
            } else {
                accelerator = nil
            }
            let maximum = try reader.readUInt64()
            let payload = try MojoRuntimeReadyPayload(
                protocolSchemaDigest: schemaDigest,
                executionContractDigest: executionDigest,
                inputGraphDigest: graphDigest,
                inputGraphIdentifier: graphIdentifier,
                bindingTableDigest: bindingDigest,
                abiVersion: abiVersion,
                targetTriple: triple,
                targetCPU: cpu,
                targetAccelerator: accelerator,
                maximumFramePayloadBytes: maximum
            )
            guard payload.maximumFramePayloadBytes
                    == limits.maximumFramePayloadBytes else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "ready payload limit differs from the admitted limit"
                )
            }
            guard payload.protocolSchemaDigest == MojoRuntimeProtocol.schemaDigest else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "protocol schema digest differs from this codec"
                )
            }
            guard reader.remainingCount == 0 else {
                throw MojoRuntimeProtocolError.trailingBytes(reader.remainingCount)
            }
            return .ready(payload)
        case .createSession:
            let payload = try MojoRuntimeCreateSessionPayload(
                bindingID: try reader.readUInt64(),
                requestSchema: try reader.readUInt32(),
                requestedDevice: try reader.readUInt32(),
                requestedOrdinal: try reader.readUInt32(),
                requiredCapabilities: try reader.readUInt64()
            )
            try Self.requireEmpty(&reader, kind: kind)
            return .createSession(payload)
        case .sessionCreated:
            let payload = try MojoRuntimeSessionCreatedPayload(
                status: try reader.readInt32(),
                responseSchema: try reader.readUInt32(),
                actualDevice: try reader.readUInt32(),
                actualOrdinal: try reader.readUInt32(),
                availableCapabilities: try reader.readUInt64()
            )
            try Self.requireEmpty(&reader, kind: kind)
            return .sessionCreated(payload)
        case .invokeFloat32:
            let bindingID = try reader.readUInt64()
            let inputCount = try reader.readUInt64()
            let outputCount = try reader.readUInt64()
            guard bindingID != 0 else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "binding identifier is zero"
                )
            }
            let count = try MojoRuntimeCheckedArithmetic.int(
                inputCount,
                label: "input element count conversion"
            )
            let byteCount = try MojoRuntimeCheckedArithmetic.multiply(
                count,
                MemoryLayout<Float32>.size,
                label: "input element count times Float32 width"
            )
            guard data.count == 24 else {
                throw MojoRuntimeProtocolError.truncatedPayload(
                    expected: 24,
                    actual: data.count
                )
            }
            guard bodyByteCount == byteCount,
                  UInt64(byteCount) <= limits.maximumFramePayloadBytes else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "Float32 body length is inconsistent or oversized"
                )
            }
            _ = try MojoRuntimeCheckedArithmetic.int(
                outputCount,
                label: "output element count conversion"
            )
            try Self.requireEmpty(&reader, kind: kind)
            return .invokeFloat32(try MojoRuntimeInvokeFloat32Payload(
                bindingID: bindingID,
                inputElementCount: inputCount,
                outputElementCount: outputCount
            ))
        case .invocationResult:
            let status = try reader.readInt32()
            let countValue = try reader.readUInt64()
            let count = try MojoRuntimeCheckedArithmetic.int(
                countValue,
                label: "result element count conversion"
            )
            let byteCount = try MojoRuntimeCheckedArithmetic.multiply(
                count,
                MemoryLayout<Float32>.size,
                label: "result element count times Float32 width"
            )
            guard data.count == 12 else {
                throw MojoRuntimeProtocolError.truncatedPayload(
                    expected: 12,
                    actual: data.count
                )
            }
            guard bodyByteCount == byteCount,
                  UInt64(byteCount) <= limits.maximumFramePayloadBytes else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "result Float32 body length is inconsistent or oversized"
                )
            }
            try Self.requireEmpty(&reader, kind: kind)
            return .invocationResult(try MojoRuntimeInvocationResultPayload(
                status: status,
                resultElementCount: countValue
            ))
        case .shutdownSession:
            try Self.requireEmpty(&reader, kind: kind)
            return .shutdownSession
        case .sessionShutdown:
            try Self.requireEmpty(&reader, kind: kind)
            return .sessionShutdown
        case .shutdownWorker:
            try Self.requireEmpty(&reader, kind: kind)
            return .shutdownWorker
        case .workerShutdown:
            try Self.requireEmpty(&reader, kind: kind)
            return .workerShutdown
        case .failure:
            let rawCode = try reader.readUInt16()
            let reserved = try reader.readUInt16()
            guard reserved == 0 else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "failure prefix reserved field is nonzero"
                )
            }
            guard let code = MojoRuntimeFailureCode(rawValue: rawCode) else {
                throw MojoRuntimeProtocolError.invalidPayload(
                    kind: kind,
                    reason: "unknown failure code"
                )
            }
            let diagnosticLength = try reader.readUInt32()
            let diagnosticCount = try MojoRuntimeCheckedArithmetic.int(
                UInt64(diagnosticLength),
                label: "failure diagnostic length conversion"
            )
            guard diagnosticCount <= MojoRuntimeFailurePayload.maximumDiagnosticByteCount else {
                throw MojoRuntimeProtocolError.payloadTooLarge(
                    length: UInt64(diagnosticCount),
                    limit: UInt64(MojoRuntimeFailurePayload.maximumDiagnosticByteCount)
                )
            }
            let diagnostic = Data(try reader.readBytes(count: diagnosticCount))
            try Self.requireEmpty(&reader, kind: kind)
            return .failure(try MojoRuntimeFailurePayload(
                code: code,
                diagnostic: diagnostic
            ))
        }
    }

    private static func requireEmpty(
        _ reader: inout MojoRuntimeByteReader,
        kind: MojoRuntimeFrameKind
    ) throws {
        guard reader.remainingCount == 0 else {
            throw MojoRuntimeProtocolError.invalidPayload(
                kind: kind,
                reason: "trailing payload bytes"
            )
        }
    }
}
