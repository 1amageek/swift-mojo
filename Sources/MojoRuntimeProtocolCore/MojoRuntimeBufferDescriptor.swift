/// Validated readonly region metadata. This value does not retain or admit storage.
package struct MojoRuntimeBufferDescriptor: Equatable, Sendable {
    package let storage: MojoRuntimeBufferStorageKind
    package let element: MojoRuntimeElementType
    package let handleOrdinal: UInt32
    package let regionByteCount: UInt64
    package let viewByteOffset: UInt64
    package let payloadOffset: UInt64
    package let dimensions: [UInt64]
    package let byteStrides: [UInt64]
    package let isEmpty: Bool
    /// Exclusive last addressed byte; empty views address no bytes.
    package let addressedByteEnd: UInt64

    package init(
        storage: MojoRuntimeBufferStorageKind,
        element: MojoRuntimeElementType,
        handleOrdinal: UInt32,
        regionByteCount: UInt64,
        viewByteOffset: UInt64,
        payloadOffset: UInt64,
        dimensions: [UInt64],
        byteStrides: [UInt64],
        limits: MojoRuntimeBufferLimits
    ) throws(MojoRuntimeBufferError) {
        guard dimensions.count == byteStrides.count else { throw .rankMismatch }
        guard dimensions.count <= Int(limits.maximumRank) else {
            throw .rankLimitExceeded
        }
        guard regionByteCount <= limits.maximumRegionByteCount else {
            throw .regionLimitExceeded
        }
        switch storage {
        case .copied:
            guard handleOrdinal == UInt32.max else { throw .invalidHandleOrdinal }
            guard payloadOffset % element.byteWidth == 0 else {
                throw .invalidPayloadOffset
            }
        case .sharedFile, .dmaBuf:
            guard handleOrdinal != UInt32.max else { throw .invalidHandleOrdinal }
            guard payloadOffset == 0 else { throw .invalidPayloadOffset }
        }
        guard viewByteOffset % element.byteWidth == 0 else { throw .unalignedView }
        guard viewByteOffset <= regionByteCount else { throw .extentOutOfBounds }
        let empty = dimensions.contains(0)
        guard !empty || limits.allowsEmpty else { throw .emptyNotAllowed }
        var end = viewByteOffset
        if !empty {
            for index in dimensions.indices {
                let stride = byteStrides[index]
                guard stride > 0 else { throw .invalidStride }
                guard dimensions[index] <= 1 || stride % element.byteWidth == 0 else {
                    throw .unalignedView
                }
                let (distance, productOverflow) =
                    (dimensions[index] - 1).multipliedReportingOverflow(by: stride)
                let (next, sumOverflow) = end.addingReportingOverflow(distance)
                guard !productOverflow, !sumOverflow else { throw .extentOverflow }
                end = next
            }
            let (last, overflow) = end.addingReportingOverflow(element.byteWidth)
            guard !overflow else { throw .extentOverflow }
            guard last <= regionByteCount else { throw .extentOutOfBounds }
            end = last
        }
        self.storage = storage
        self.element = element
        self.handleOrdinal = handleOrdinal
        self.regionByteCount = regionByteCount
        self.viewByteOffset = viewByteOffset
        self.payloadOffset = payloadOffset
        self.dimensions = dimensions
        self.byteStrides = byteStrides
        self.isEmpty = empty
        self.addressedByteEnd = end
    }

    package func encode(into writer: inout MojoRuntimeByteWriter) {
        writer.appendUInt16(storage.rawValue)
        writer.appendUInt16(element.rawValue)
        // Construction proved rank fits its UInt16 manifest limit.
        writer.appendUInt16(UInt16(dimensions.count))
        writer.appendUInt16(0)
        writer.appendUInt32(handleOrdinal)
        writer.appendUInt32(0)
        writer.appendUInt64(regionByteCount)
        writer.appendUInt64(viewByteOffset)
        writer.appendUInt64(payloadOffset)
        for index in dimensions.indices {
            writer.appendUInt64(dimensions[index])
            writer.appendUInt64(byteStrides[index])
        }
    }

    package static func decode(
        from reader: inout MojoRuntimeByteReader,
        limits: MojoRuntimeBufferLimits
    ) throws -> Self {
        let storageID = try reader.readUInt16()
        guard let storage = MojoRuntimeBufferStorageKind(rawValue: storageID) else {
            throw MojoRuntimeBufferError.unknownStorage(storageID)
        }
        let elementID = try reader.readUInt16()
        guard let element = MojoRuntimeElementType(rawValue: elementID) else {
            throw MojoRuntimeBufferError.unknownElement(elementID)
        }
        let rank = try reader.readUInt16()
        guard rank <= limits.maximumRank else {
            throw MojoRuntimeBufferError.rankLimitExceeded
        }
        let reserved16 = try reader.readUInt16()
        guard reserved16 == 0 else {
            throw MojoRuntimeProtocolError.reservedFieldNonZero(UInt64(reserved16))
        }
        let ordinal = try reader.readUInt32()
        let reserved32 = try reader.readUInt32()
        guard reserved32 == 0 else {
            throw MojoRuntimeProtocolError.reservedFieldNonZero(UInt64(reserved32))
        }
        let byteCount = try reader.readUInt64()
        let offset = try reader.readUInt64()
        let payloadOffset = try reader.readUInt64()
        // UInt16 rank * 16 is representable on supported hosts. Reject
        // truncation before reserving any dimension/stride storage.
        let metadataCount = Int(rank) * MojoRuntimeResourceProtocol.dimensionByteCount
        guard reader.remainingCount >= metadataCount else {
            throw MojoRuntimeProtocolError.truncatedPayload(
                expected: metadataCount, actual: reader.remainingCount
            )
        }
        var dimensions: [UInt64] = []
        var strides: [UInt64] = []
        dimensions.reserveCapacity(Int(rank))
        strides.reserveCapacity(Int(rank))
        for _ in 0..<rank {
            dimensions.append(try reader.readUInt64())
            strides.append(try reader.readUInt64())
        }
        return try Self(
            storage: storage, element: element, handleOrdinal: ordinal,
            regionByteCount: byteCount, viewByteOffset: offset,
            payloadOffset: payloadOffset, dimensions: dimensions,
            byteStrides: strides, limits: limits
        )
    }
}
