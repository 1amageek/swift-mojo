/// Distinct wire, mapping and result bounds selected by the verified binding.
package struct MojoRuntimeResourceLimits: Sendable {
    package let buffer: MojoRuntimeBufferLimits
    package let maximumInputs: UInt16
    package let maximumOutputs: UInt16
    package let maximumArgumentBytes: UInt32
    package let maximumResultValueBytes: UInt32
    package let maximumControlBytes: UInt64
    package let maximumCopiedBytes: UInt64
    package let maximumMappedBytes: UInt64
    package let maximumResultBytes: UInt64

    package init(
        buffer: MojoRuntimeBufferLimits, maximumInputs: UInt16,
        maximumOutputs: UInt16, maximumArgumentBytes: UInt32,
        maximumResultValueBytes: UInt32,
        maximumControlBytes: UInt64, maximumCopiedBytes: UInt64,
        maximumMappedBytes: UInt64, maximumResultBytes: UInt64
    ) throws(MojoRuntimeBufferError) {
        guard maximumControlBytes >= UInt64(MojoRuntimeResourceProtocol.invocationPrefixByteCount),
              maximumControlBytes <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes,
              maximumCopiedBytes <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes,
              maximumResultBytes <= MojoRuntimeProtocol.hardMaximumFramePayloadBytes,
              maximumArgumentBytes <= maximumControlBytes,
              maximumResultValueBytes <= maximumControlBytes,
              UInt64(maximumResultValueBytes) + UInt64(MojoRuntimeResourceProtocol.resultPrefixByteCount) <= maximumResultBytes,
              maximumMappedBytes <= UInt64(Int.max) else {
            throw .invalidLimits
        }
        self.buffer = buffer
        self.maximumInputs = maximumInputs
        self.maximumOutputs = maximumOutputs
        self.maximumArgumentBytes = maximumArgumentBytes
        self.maximumResultValueBytes = maximumResultValueBytes
        self.maximumControlBytes = maximumControlBytes
        self.maximumCopiedBytes = maximumCopiedBytes
        self.maximumMappedBytes = maximumMappedBytes
        self.maximumResultBytes = maximumResultBytes
    }
}
