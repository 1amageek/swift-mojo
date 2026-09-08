/// Caller-owned bounds for one worker input-resource set.
public struct MojoRuntimeWorkerInputResourceLimits: Sendable {
    public let maximumResourceCount: Int
    public let maximumAggregateByteCount: Int64

    public init(
        maximumResourceCount: Int,
        maximumAggregateByteCount: Int64
    ) throws {
        guard maximumResourceCount > 0,
              maximumAggregateByteCount > 0 else {
            throw MojoRuntimeWorkerError.invalidInputResourceLimits
        }
        self.maximumResourceCount = maximumResourceCount
        self.maximumAggregateByteCount = maximumAggregateByteCount
    }
}
