import Foundation
import Testing
import MojoRuntimeProtocolCore

@Suite("Mojo runtime protocol core")
struct MojoRuntimeProtocolCoreTests {
    private var limits: MojoRuntimeProtocolLimits {
        do {
            return try MojoRuntimeProtocolLimits(
                maximumFramePayloadBytes: 4_096
            )
        } catch {
            fatalError("fixed protocol test limit is invalid: \(error)")
        }
    }

    @Test("fixed header uses the SMW1 little-endian golden bytes", .timeLimit(.minutes(1)))
    func headerGoldenBytes() throws {
        let header = try MojoRuntimeFrameHeader(
            kind: .shutdownSession,
            requestID: 7,
            payloadByteCount: 0
        )
        #expect(header.encodedBytes() == [
            0x53, 0x4D, 0x57, 0x31,
            0x01, 0x00,
            0x06, 0x00,
            0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(
            try MojoRuntimeFrameHeader.decode(
                header.encodedData(),
                limits: limits
            ) == header
        )
    }

    @Test("every closed frame kind has a typed round trip", .timeLimit(.minutes(1)))
    func closedKindsRoundTrip() throws {
        let digest = String(repeating: "a", count: 64)
        let ready = try MojoRuntimeReadyPayload(
            executionContractDigest: digest,
            inputGraphDigest: digest,
            inputGraphIdentifier: 11,
            bindingTableDigest: digest,
            abiVersion: 1,
            targetTriple: "arm64-apple-macosx15.0",
            targetCPU: "generic",
            targetAccelerator: nil,
            maximumFramePayloadBytes: limits.maximumFramePayloadBytes
        )
        let values: [(UInt64, MojoRuntimePayload)] = [
            (0, .ready(ready)),
            (1, .createSession(try MojoRuntimeCreateSessionPayload(
                bindingID: 41,
                requestedDevice: 1,
                requestedOrdinal: 0,
                requiredCapabilities: 3
            ))),
            (1, .sessionCreated(try MojoRuntimeSessionCreatedPayload(
                status: 0,
                responseSchema: 1,
                actualDevice: 1,
                actualOrdinal: 0,
                availableCapabilities: 3
            ))),
            (2, .invokeFloat32(try MojoRuntimeInvokeFloat32Payload(
                bindingID: 41,
                inputElementCount: 0
            ))),
            (2, .invocationResult(try MojoRuntimeInvocationResultPayload(
                status: 0,
                resultElementCount: 0
            ))),
            (3, .shutdownSession),
            (3, .sessionShutdown),
            (4, .shutdownWorker),
            (4, .workerShutdown),
            (0, .failure(try MojoRuntimeFailurePayload(
                code: .invalidFrame,
                diagnostic: "bad frame"
            ))),
        ]
        for (requestID, payload) in values {
            let frame = try MojoRuntimeFrame(
                requestID: requestID,
                payload: payload,
                limits: limits
            )
            let decoded = try MojoRuntimeFrame.decode(
                try frame.encodedData(limits: limits),
                limits: limits
            )
            #expect(decoded == frame)
            #expect(decoded.header.kind == payload.kind)
        }
        let createFrame = try MojoRuntimeFrame(
            requestID: 1,
            payload: values[1].1,
            limits: limits
        )
        let createBytes = try createFrame.encodedData(limits: limits)
        #expect(Array(createBytes[32..<40]) == [
            41, 0, 0, 0, 0, 0, 0, 0,
        ])
    }

    @Test("tensor body is a separately bounded segment", .timeLimit(.minutes(1)))
    func tensorBodyUsesPrefixOnly() throws {
        let payload = try MojoRuntimeInvokeFloat32Payload(
            bindingID: 41,
            inputElementCount: 1
        )
        let frame = try MojoRuntimeFrame(
            requestID: 1,
            payload: .invokeFloat32(payload),
            limits: limits
        )
        #expect(frame.header.payloadByteCount == 28)
        let prefixData = try frame.encodedPrefixData(limits: limits)
        #expect(prefixData.count == 56)
        #expect(Array(prefixData[32..<56]) == [
            41, 0, 0, 0, 0, 0, 0, 0,
            1, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        ])
        #expect(throws: MojoRuntimeProtocolError.tensorBodyRequiresBorrowedSegment) {
            try frame.encodedData(limits: limits)
        }
    }

    @Test("segmented prefix decoding validates body length without materializing the body", .timeLimit(.minutes(1)))
    func segmentedPrefixDecoding() throws {
        let invokePayload = try MojoRuntimeInvokeFloat32Payload(
            bindingID: 41,
            inputElementCount: 2,
            outputElementCount: 3
        )
        let invokeFrame = try MojoRuntimeFrame(
            requestID: 1,
            payload: .invokeFloat32(invokePayload),
            limits: limits
        )
        let invokePrefix = try invokeFrame.encodedPrefixData(limits: limits)
        let invokeDecoded = try MojoRuntimeFrame.decodePrefix(
            headerData: Data(invokePrefix.prefix(32)),
            payloadPrefixData: Data(invokePrefix.dropFirst(32)),
            limits: limits
        )
        #expect(invokeDecoded.header == invokeFrame.header)
        #expect(invokeDecoded.payload == invokeFrame.payload)
        #expect(invokeDecoded.bodyByteCount == 8)

        let resultPayload = try MojoRuntimeInvocationResultPayload(
            status: 0,
            resultElementCount: 3
        )
        let resultFrame = try MojoRuntimeFrame(
            requestID: 1,
            payload: .invocationResult(resultPayload),
            limits: limits
        )
        let resultPrefix = try resultFrame.encodedPrefixData(limits: limits)
        let resultDecoded = try MojoRuntimeFrame.decodePrefix(
            headerData: Data(resultPrefix.prefix(32)),
            payloadPrefixData: Data(resultPrefix.dropFirst(32)),
            limits: limits
        )
        #expect(resultDecoded.bodyByteCount == 12)
        #expect(resultDecoded.payload == resultFrame.payload)
    }

    @Test("segmented codec rejects every tensor and fixed-prefix boundary", .timeLimit(.minutes(1)))
    func segmentedBoundaryFailures() throws {
        let invoke = try MojoRuntimeFrame(
            requestID: 1,
            payload: .invokeFloat32(try MojoRuntimeInvokeFloat32Payload(
                bindingID: 41,
                inputElementCount: 2,
                outputElementCount: 1
            )),
            limits: limits
        )
        let invokePrefix = try invoke.encodedPrefixData(limits: limits)
        let invokeHeader = Data(invokePrefix.prefix(32))
        let invokePayloadPrefix = Data(invokePrefix.dropFirst(32))
        for malformedPrefix in [
            Data(invokePayloadPrefix.dropLast()),
            invokePayloadPrefix + Data([0x01]),
        ] {
            #expect(throws: MojoRuntimeProtocolError.self) {
                try MojoRuntimeFrame.decodePrefix(
                    headerData: invokeHeader,
                    payloadPrefixData: malformedPrefix,
                    limits: limits
                )
            }
        }
        for malformedLength in [UInt64(31), UInt64(33)] {
            #expect(throws: MojoRuntimeProtocolError.self) {
                try MojoRuntimeFrame.decodePrefix(
                    headerData: header(
                        from: invokeHeader,
                        payloadLength: malformedLength
                    ),
                    payloadPrefixData: invokePayloadPrefix,
                    limits: limits
                )
            }
        }

        let result = try MojoRuntimeFrame(
            requestID: 1,
            payload: .invocationResult(try MojoRuntimeInvocationResultPayload(
                status: 0,
                resultElementCount: 2
            )),
            limits: limits
        )
        let resultPrefix = try result.encodedPrefixData(limits: limits)
        let resultHeader = Data(resultPrefix.prefix(32))
        let resultPayloadPrefix = Data(resultPrefix.dropFirst(32))
        for malformedPrefix in [
            Data(resultPayloadPrefix.dropLast()),
            resultPayloadPrefix + Data([0x01]),
        ] {
            #expect(throws: MojoRuntimeProtocolError.self) {
                try MojoRuntimeFrame.decodePrefix(
                    headerData: resultHeader,
                    payloadPrefixData: malformedPrefix,
                    limits: limits
                )
            }
        }
        for malformedLength in [UInt64(19), UInt64(21)] {
            #expect(throws: MojoRuntimeProtocolError.self) {
                try MojoRuntimeFrame.decodePrefix(
                    headerData: header(
                        from: resultHeader,
                        payloadLength: malformedLength
                    ),
                    payloadPrefixData: resultPayloadPrefix,
                    limits: limits
                )
            }
        }

        let exactInvoke = invokePrefix + Data(repeating: 0, count: 8)
        #expect(
            try MojoRuntimeFrame.decode(exactInvoke, limits: limits)
                == invoke
        )
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decode(
                exactInvoke.dropLast(),
                limits: limits
            )
        }
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decode(
                exactInvoke + Data([0]),
                limits: limits
            )
        }

        let shutdown = try MojoRuntimeFrame(
            requestID: 1,
            payload: .shutdownSession,
            limits: limits
        )
        let shutdownHeader = shutdown.header.encodedData()
        #expect(
            try MojoRuntimeFrame.decodePrefix(
                headerData: shutdownHeader,
                payloadPrefixData: Data(),
                limits: limits
            ).payload == .shutdownSession
        )
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decodePrefix(
                headerData: header(
                    from: shutdownHeader,
                    payloadLength: 1
                ),
                payloadPrefixData: Data(),
                limits: limits
            )
        }
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decodePrefix(
                headerData: shutdownHeader,
                payloadPrefixData: Data([0]),
                limits: limits
            )
        }
    }

    @Test("malformed fixed header fields are rejected", .timeLimit(.minutes(1)))
    func malformedHeaders() throws {
        let header = try MojoRuntimeFrameHeader(
            kind: .shutdownSession,
            requestID: 1,
            payloadByteCount: 0
        )
        let original = header.encodedBytes()
        var badMagic = original
        badMagic[0] = 0
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(badMagic), limits: limits)
        }
        var badVersion = original
        badVersion[4] = 2
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(badVersion), limits: limits)
        }
        var badKind = original
        badKind[6] = 0xFF
        badKind[7] = 0x7F
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(badKind), limits: limits)
        }
        var badReserved = original
        badReserved[24] = 1
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(badReserved), limits: limits)
        }
        var badReadyID = try MojoRuntimeFrameHeader(
            kind: .ready,
            requestID: 0,
            payloadByteCount: 0
        ).encodedBytes()
        badReadyID[8] = 1
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(badReadyID), limits: limits)
        }
    }

    @Test("truncated, oversized, trailing, and checked arithmetic paths fail", .timeLimit(.minutes(1)))
    func boundedFailures() throws {
        let header = try MojoRuntimeFrameHeader(
            kind: .shutdownSession,
            requestID: 1,
            payloadByteCount: 1
        )
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decode(
                Data(header.encodedBytes()),
                limits: limits
            )
        }
        var oversized = header.encodedBytes()
        oversized.replaceSubrange(16..<24, with: [
            0x01, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        ])
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrameHeader.decode(Data(oversized), limits: limits)
        }
        let valid = try MojoRuntimeFrame(
            requestID: 1,
            payload: .shutdownSession,
            limits: limits
        ).encodedData(limits: limits)
        #expect(throws: MojoRuntimeProtocolError.self) {
            try MojoRuntimeFrame.decode(
                valid + Data([0x01]),
                limits: limits
            )
        }
        #expect(throws: MojoRuntimeProtocolError.self) {
            _ = try MojoRuntimeCheckedArithmetic.int(
                UInt64.max,
                label: "test conversion"
            )
        }
        #expect(throws: MojoRuntimeProtocolError.self) {
            _ = try MojoRuntimeCheckedArithmetic.multiply(
                Int.max,
                4,
                label: "test multiplication"
            )
        }
    }

    @Test("consumer and worker sequence validation pairs one request", .timeLimit(.minutes(1)))
    func sequenceValidation() throws {
        let ready = try MojoRuntimeFrame(
            requestID: 0,
            payload: .ready(try readyPayload()),
            limits: limits
        )
        var consumer = MojoRuntimeProtocolSequenceValidator(role: .consumer)
        try consumer.accept(ready, direction: .incoming)
        let create = try MojoRuntimeFrame(
            requestID: 1,
            payload: .createSession(try MojoRuntimeCreateSessionPayload(
                bindingID: 41,
                requestedDevice: 1,
                requestedOrdinal: 0,
                requiredCapabilities: 0
            )),
            limits: limits
        )
        try consumer.accept(create, direction: .outgoing)
        let duplicate = try MojoRuntimeFrame(
            requestID: 2,
            payload: .invokeFloat32(try MojoRuntimeInvokeFloat32Payload(
                bindingID: 41,
                inputElementCount: 0
            )),
            limits: limits
        )
        #expect(throws: MojoRuntimeProtocolError.secondInFlight) {
            try consumer.accept(duplicate, direction: .outgoing)
        }
        let created = try MojoRuntimeFrame(
            requestID: 9,
            payload: .sessionCreated(try MojoRuntimeSessionCreatedPayload(
                status: 0,
                responseSchema: 1,
                actualDevice: 1,
                actualOrdinal: 0,
                availableCapabilities: 0
            )),
            limits: limits
        )
        #expect(throws: MojoRuntimeProtocolError.responseIdentifierMismatch(expected: 1, actual: 9)) {
            try consumer.accept(created, direction: .incoming)
        }
        let createdPaired = try MojoRuntimeFrame(
            requestID: 1,
            payload: .sessionCreated(try MojoRuntimeSessionCreatedPayload(
                status: 0,
                responseSchema: 1,
                actualDevice: 1,
                actualOrdinal: 0,
                availableCapabilities: 0
            )),
            limits: limits
        )
        try consumer.accept(createdPaired, direction: .incoming)
    }

    @Test("startup failure is terminal and creation failure is not a session", .timeLimit(.minutes(1)))
    func failureState() throws {
        var consumer = MojoRuntimeProtocolSequenceValidator(role: .consumer)
        let failure = try MojoRuntimeFrame(
            requestID: 0,
            payload: .failure(try MojoRuntimeFailurePayload(code: .invalidFrame)),
            limits: limits
        )
        try consumer.accept(failure, direction: .incoming)
        #expect(consumer.isTerminal)
        #expect(throws: MojoRuntimeProtocolError.self) {
            _ = try MojoRuntimeSessionCreatedPayload(
                status: 9,
                responseSchema: 1,
                actualDevice: 0,
                actualOrdinal: 0,
                availableCapabilities: 0
            )
        }
    }

    private func readyPayload() throws -> MojoRuntimeReadyPayload {
        let digest = String(repeating: "a", count: 64)
        return try MojoRuntimeReadyPayload(
            executionContractDigest: digest,
            inputGraphDigest: digest,
            inputGraphIdentifier: 11,
            bindingTableDigest: digest,
            abiVersion: 1,
            targetTriple: "arm64-apple-macosx15.0",
            targetCPU: "generic",
            targetAccelerator: nil,
            maximumFramePayloadBytes: limits.maximumFramePayloadBytes
        )
    }

    private func header(from data: Data, payloadLength: UInt64) -> Data {
        var bytes = Array(data)
        for offset in 0..<MemoryLayout<UInt64>.size {
            bytes[16 + offset] = UInt8(
                truncatingIfNeeded: payloadLength >> UInt64(offset * 8)
            )
        }
        return Data(bytes)
    }
}
