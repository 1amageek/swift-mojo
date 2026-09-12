package enum MojoRuntimeBufferError: Error, Equatable, Sendable {
    case invalidLimits
    case invalidBinding
    case invalidSchema
    case countLimitExceeded
    case aggregateLimitExceeded
    case inconsistentSharedRegion
    case failedResultHasOutput
    case resultCountMismatch
    case unknownStorage(UInt16)
    case unknownElement(UInt16)
    case rankMismatch
    case rankLimitExceeded
    case regionLimitExceeded
    case invalidHandleOrdinal
    case invalidPayloadOffset
    case unalignedView
    case emptyNotAllowed
    case invalidStride
    case extentOverflow
    case extentOutOfBounds
}
