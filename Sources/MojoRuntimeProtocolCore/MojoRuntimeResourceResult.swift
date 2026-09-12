import Foundation

/// Bounded v2 terminal result metadata; output bytes remain a borrowed segment.
package struct MojoRuntimeResourceResult: Equatable, Sendable {
    package let status: Int32
    package let outputSchema: [UInt8]
    package let values: Data
    package let elementCounts: [UInt64]
    package let bodyByteCount: UInt64

    package init(
        status: Int32, outputSchema: [UInt8], values: Data,
        elementCounts: [UInt64], expectedSchema: [UInt8],
        capacities: [MojoRuntimeOutputCapacity], limits: MojoRuntimeResourceLimits
    ) throws {
        guard outputSchema.count == 32, outputSchema == expectedSchema else {
            throw MojoRuntimeBufferError.invalidSchema
        }
        guard capacities.count <= Int(limits.maximumOutputs),
              elementCounts.count <= Int(limits.maximumOutputs),
              values.count <= Int(limits.maximumResultValueBytes) else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        guard status == 0 || (values.isEmpty && elementCounts.isEmpty) else {
            throw MojoRuntimeBufferError.failedResultHasOutput
        }
        guard status != 0 || elementCounts.count == capacities.count else {
            throw MojoRuntimeBufferError.resultCountMismatch
        }
        var body: UInt64 = 0
        for index in elementCounts.indices {
            guard elementCounts[index] <= capacities[index].maximumElementCount else {
                throw MojoRuntimeBufferError.countLimitExceeded
            }
            let (bytes, productOverflow) =
                elementCounts[index].multipliedReportingOverflow(by: capacities[index].element.byteWidth)
            let (next, sumOverflow) = body.addingReportingOverflow(bytes)
            guard !productOverflow, !sumOverflow else {
                throw MojoRuntimeBufferError.extentOverflow
            }
            body = next
        }
        let prefix: UInt64 = UInt64(MojoRuntimeResourceProtocol.resultPrefixByteCount) + UInt64(elementCounts.count) * 8 + UInt64(values.count)
        guard prefix <= limits.maximumControlBytes,
              body <= limits.maximumResultBytes,
              prefix <= limits.maximumResultBytes - body else {
            throw MojoRuntimeBufferError.aggregateLimitExceeded
        }
        self.status = status
        self.outputSchema = outputSchema
        self.values = values
        self.elementCounts = elementCounts
        self.bodyByteCount = body
    }

    package func encodedControl() -> Data {
        var writer = MojoRuntimeByteWriter(reservingCapacity: MojoRuntimeResourceProtocol.resultPrefixByteCount + elementCounts.count * 8 + values.count)
        writer.appendInt32(status)
        writer.append(contentsOf: outputSchema)
        writer.appendUInt32(UInt32(values.count))
        writer.appendUInt16(UInt16(elementCounts.count))
        writer.appendUInt16(0)
        for count in elementCounts { writer.appendUInt64(count) }
        writer.append(contentsOf: Array(values))
        return writer.data()
    }

    package static func decodeControl(
        _ data: Data, expectedSchema: [UInt8],
        capacities: [MojoRuntimeOutputCapacity], limits: MojoRuntimeResourceLimits
    ) throws -> Self {
        guard UInt64(data.count) <= limits.maximumControlBytes else {
            throw MojoRuntimeBufferError.aggregateLimitExceeded
        }
        var reader = MojoRuntimeByteReader(data: data)
        let status = try reader.readInt32()
        let schema = try reader.readBytes(count: 32)
        let valueCount = try reader.readUInt32()
        let outputCount = try reader.readUInt16()
        let reserved = try reader.readUInt16()
        guard reserved == 0 else {
            throw MojoRuntimeProtocolError.reservedFieldNonZero(UInt64(reserved))
        }
        guard outputCount <= limits.maximumOutputs,
              valueCount <= limits.maximumResultValueBytes else {
            throw MojoRuntimeBufferError.countLimitExceeded
        }
        let remaining = UInt64(outputCount) * 8 + UInt64(valueCount)
        guard remaining == UInt64(reader.remainingCount) else {
            throw MojoRuntimeProtocolError.invalidPayloadLength
        }
        var counts: [UInt64] = []
        counts.reserveCapacity(Int(outputCount))
        for _ in 0..<outputCount { counts.append(try reader.readUInt64()) }
        let values = Data(try reader.readBytes(count: Int(valueCount)))
        return try Self(
            status: status, outputSchema: schema, values: values,
            elementCounts: counts, expectedSchema: expectedSchema,
            capacities: capacities, limits: limits
        )
    }
}
