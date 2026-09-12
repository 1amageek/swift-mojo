import Foundation

/// Canonical v2 invocation metadata. Bulk input is a separate borrowed segment.
package struct MojoRuntimeResourceInvocation: Equatable, Sendable {
    package let bindingID: UInt64
    package let argumentSchema: [UInt8]
    package let arguments: Data
    package let inputs: [MojoRuntimeBufferDescriptor]
    package let outputs: [MojoRuntimeOutputCapacity]
    package let copiedBodyByteCount: UInt64
    package let mappedByteCount: UInt64
    package let sharedHandleCount: Int
    package let controlByteCount: Int

    package init(
        bindingID: UInt64, argumentSchema: [UInt8], arguments: Data,
        inputs: [MojoRuntimeBufferDescriptor], outputs: [MojoRuntimeOutputCapacity],
        limits: MojoRuntimeResourceLimits
    ) throws {
        guard bindingID != 0 else { throw MojoRuntimeBufferError.invalidBinding }
        guard argumentSchema.count == 32 else { throw MojoRuntimeBufferError.invalidSchema }
        guard inputs.count <= Int(limits.maximumInputs),
              outputs.count <= Int(limits.maximumOutputs),
              arguments.count <= Int(limits.maximumArgumentBytes) else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        var control: UInt64 = UInt64(MojoRuntimeResourceProtocol.invocationPrefixByteCount) + UInt64(arguments.count) + UInt64(outputs.count) * UInt64(MojoRuntimeResourceProtocol.outputCapacityByteCount)
        var copied: UInt64 = 0
        var mapped: UInt64 = 0
        var handles: [UInt32: MojoRuntimeBufferDescriptor] = [:]
        for input in inputs {
            // Revalidate against this invocation's binding limits. A descriptor
            // constructed under another binding is not admission evidence.
            _ = try MojoRuntimeBufferDescriptor(
                storage: input.storage, element: input.element,
                handleOrdinal: input.handleOrdinal, regionByteCount: input.regionByteCount,
                viewByteOffset: input.viewByteOffset, payloadOffset: input.payloadOffset,
                dimensions: input.dimensions, byteStrides: input.byteStrides,
                limits: limits.buffer
            )
            control += UInt64(MojoRuntimeResourceProtocol.bufferPrefixByteCount) + UInt64(input.dimensions.count) * UInt64(MojoRuntimeResourceProtocol.dimensionByteCount)
            if input.storage == .copied {
                let (end, overflow) = input.payloadOffset.addingReportingOverflow(input.regionByteCount)
                guard !overflow else { throw MojoRuntimeBufferError.extentOverflow }
                copied = max(copied, end)
            } else if let previous = handles[input.handleOrdinal] {
                guard previous.storage == input.storage,
                      previous.regionByteCount == input.regionByteCount else {
                    throw MojoRuntimeBufferError.inconsistentSharedRegion
                }
            } else {
                guard input.handleOrdinal < UInt32(inputs.count) else {
                    throw MojoRuntimeBufferError.invalidHandleOrdinal
                }
                handles[input.handleOrdinal] = input
                let (next, overflow) = mapped.addingReportingOverflow(input.regionByteCount)
                guard !overflow else { throw MojoRuntimeBufferError.extentOverflow }
                mapped = next
            }
        }
        for ordinal in 0..<handles.count {
            guard handles[UInt32(ordinal)] != nil else {
                throw MojoRuntimeBufferError.invalidHandleOrdinal
            }
        }
        var outputBytes: UInt64 = 0
        for output in outputs {
            let (next, overflow) = outputBytes.addingReportingOverflow(output.maximumByteCount)
            guard !overflow else { throw MojoRuntimeBufferError.extentOverflow }
            outputBytes = next
        }
        guard control <= limits.maximumControlBytes,
              copied <= limits.maximumCopiedBytes,
              control + copied <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes,
              mapped <= limits.maximumMappedBytes,
              outputBytes <= limits.maximumResultBytes,
              UInt64(MojoRuntimeResourceProtocol.resultPrefixByteCount)
                + UInt64(outputs.count) * 8 + UInt64(limits.maximumResultValueBytes)
                <= limits.maximumResultBytes - outputBytes else {
            throw MojoRuntimeBufferError.aggregateLimitExceeded
        }
        self.bindingID = bindingID
        self.argumentSchema = argumentSchema
        self.arguments = arguments
        self.inputs = inputs
        self.outputs = outputs
        self.copiedBodyByteCount = copied
        self.mappedByteCount = mapped
        self.sharedHandleCount = handles.count
        self.controlByteCount = Int(control)
    }

    package func encodedControl() -> Data {
        var writer = MojoRuntimeByteWriter(reservingCapacity: controlByteCount)
        writer.appendUInt64(bindingID)
        writer.append(contentsOf: argumentSchema)
        writer.appendUInt32(UInt32(arguments.count))
        writer.appendUInt16(UInt16(inputs.count))
        writer.appendUInt16(UInt16(outputs.count))
        for input in inputs { input.encode(into: &writer) }
        for output in outputs {
            writer.appendUInt16(output.element.rawValue)
            writer.appendUInt16(0)
            writer.appendUInt64(output.maximumElementCount)
        }
        // Only bounded argument metadata is materialized, never input pixels/samples.
        writer.append(contentsOf: Array(arguments))
        return writer.data()
    }

    package static func decodeControl(
        _ data: Data, limits: MojoRuntimeResourceLimits
    ) throws -> Self {
        guard UInt64(data.count) <= limits.maximumControlBytes else {
            throw MojoRuntimeBufferError.aggregateLimitExceeded
        }
        var reader = MojoRuntimeByteReader(data: data)
        let binding = try reader.readUInt64()
        let schema = try reader.readBytes(count: 32)
        let argumentCount = try reader.readUInt32()
        let inputCount = try reader.readUInt16()
        let outputCount = try reader.readUInt16()
        guard inputCount <= limits.maximumInputs,
              outputCount <= limits.maximumOutputs,
              argumentCount <= limits.maximumArgumentBytes else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        let minimumRemaining = UInt64(inputCount) * UInt64(MojoRuntimeResourceProtocol.bufferPrefixByteCount)
            + UInt64(outputCount) * UInt64(MojoRuntimeResourceProtocol.outputCapacityByteCount) + UInt64(argumentCount)
        guard minimumRemaining <= UInt64(reader.remainingCount) else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: Int(minimumRemaining), actual: reader.remainingCount
            )
        }
        var inputs: [MojoRuntimeBufferDescriptor] = []
        var outputs: [MojoRuntimeOutputCapacity] = []
        inputs.reserveCapacity(Int(inputCount))
        outputs.reserveCapacity(Int(outputCount))
        for _ in 0..<inputCount {
            inputs.append(try .decode(from: &reader, limits: limits.buffer))
        }
        for _ in 0..<outputCount {
            let typeID = try reader.readUInt16()
            guard let type = MojoRuntimeElementType(rawValue: typeID) else {
                throw MojoRuntimeBufferError.unknownElement(typeID)
            }
            let reserved = try reader.readUInt16()
            guard reserved == 0 else {
                throw MojoRuntimeProtocolError.reservedFieldNonZero(UInt64(reserved))
            }
            outputs.append(try .init(
                element: type, maximumElementCount: reader.readUInt64()
            ))
        }
        let arguments = Data(try reader.readBytes(count: Int(argumentCount)))
        guard reader.remainingCount == 0 else {
            throw MojoRuntimeProtocolError.trailingBytes(reader.remainingCount)
        }
        return try Self(
            bindingID: binding, argumentSchema: schema, arguments: arguments,
            inputs: inputs, outputs: outputs, limits: limits
        )
    }
}
