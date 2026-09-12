import Foundation
import MojoPOSIXSupport
import MojoRuntimeProtocolCore

package struct MojoRuntimeResourceExchange: Sendable {
    package let requestID: UInt64
    package let invocation: MojoRuntimePreparedInvocation
    package let expectedResultSchema: [UInt8]
    package let limits: MojoRuntimeResourceLimits
    package let process: MojoPOSIXWorkerProcess
    package let gate: MojoRuntimeWorkerCancellationGate
    package let lease: MojoRuntimeWorkerCancellationGate.Lease
    package let deadline: ContinuousClock.Instant

    package init(
        requestID: UInt64, invocation: MojoRuntimePreparedInvocation,
        expectedResultSchema: [UInt8], limits: MojoRuntimeResourceLimits,
        process: MojoPOSIXWorkerProcess, gate: MojoRuntimeWorkerCancellationGate,
        lease: MojoRuntimeWorkerCancellationGate.Lease, deadline: ContinuousClock.Instant
    ) {
        self.requestID = requestID
        self.invocation = invocation
        self.expectedResultSchema = expectedResultSchema
        self.limits = limits
        self.process = process
        self.gate = gate
        self.lease = lease
        self.deadline = deadline
    }
}

package struct MojoRuntimeResourceExchangeResult: Sendable {
    package let metadata: MojoRuntimeResourceResult
    package let outputBuffers: [Data]
    package let controlBytesSent: UInt64
    package let inputPayloadBytesSent: UInt64
    package let sharedHandlesSent: Int
}
