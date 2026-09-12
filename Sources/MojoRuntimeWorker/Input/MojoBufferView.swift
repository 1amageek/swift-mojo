import MojoRuntimeProtocolCore

/// A retained readonly layout. No storage is borrowed or repacked at construction.
public struct MojoBufferView: Sendable {
    public let buffer: MojoReadOnlyBuffer
    public let elementType: MojoBufferElementType
    public let byteOffset: UInt64
    public let dimensions: [UInt64]
    public let byteStrides: [UInt64]

    public init(
        buffer: MojoReadOnlyBuffer, elementType: MojoBufferElementType,
        byteOffset: UInt64 = 0, dimensions: [UInt64], byteStrides: [UInt64]
    ) throws(MojoInputBufferError) {
        do {
            // This checks owner extent only. Invocation revalidates the layout
            // against the selected binding before granting transport authority.
            let limits = try MojoRuntimeBufferLimits(
                maximumRank: UInt16.max, maximumRegionByteCount: UInt64(Int.max),
                allowsEmpty: true
            )
            _ = try MojoRuntimeBufferDescriptor(
                storage: .copied, element: elementType.wireType,
                handleOrdinal: UInt32.max, regionByteCount: UInt64(buffer.byteCount),
                viewByteOffset: byteOffset, payloadOffset: 0,
                dimensions: dimensions, byteStrides: byteStrides, limits: limits
            )
        } catch {
            throw .invalidLayout(diagnostic: String(describing: error))
        }
        self.buffer = buffer
        self.elementType = elementType
        self.byteOffset = byteOffset
        self.dimensions = dimensions
        self.byteStrides = byteStrides
    }
}
