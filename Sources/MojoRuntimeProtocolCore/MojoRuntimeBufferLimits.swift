/// Caller-admitted maxima, applied before allocating descriptor metadata.
package struct MojoRuntimeBufferLimits: Equatable, Sendable {
    package let maximumRank: UInt16
    package let maximumRegionByteCount: UInt64
    package let allowsEmpty: Bool

    package init(
        maximumRank: UInt16,
        maximumRegionByteCount: UInt64,
        allowsEmpty: Bool
    ) throws(MojoRuntimeBufferError) {
        guard maximumRegionByteCount > 0,
              maximumRegionByteCount <= UInt64(Int.max) else {
            throw .invalidLimits
        }
        self.maximumRank = maximumRank
        self.maximumRegionByteCount = maximumRegionByteCount
        self.allowsEmpty = allowsEmpty
    }
}
