import Mojo
import MojoAllocationProbe

@main
struct AllocationAcceptance {
    static func main() throws {
        // A positive control must prove that interception is active.
        swift_mojo_probe_begin()
        let control = UnsafeMutableBufferPointer<Float>.allocate(capacity: 8192)
        let controlCount = swift_mojo_probe_end()
        control.initialize(repeating: 2)
        defer { control.deinitialize(); control.deallocate() }
        guard controlCount > 0 else { throw ProbeError.positiveControlFailed }

        let session = try integrationOpenSession(.init(device: .cpu,
            requiredCapabilities: [.synchronousInvocation, .hostAccessibleMemory, .float32]))
        defer { do { try session.shutdown() } catch { fatalError("Shutdown failed: \(error)") } }
        for count in [1, 4096, 1048576] {
            let source = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            let destination = UnsafeMutableBufferPointer<Float>.allocate(capacity: count)
            source.initialize(repeating: 2)
            destination.initialize(repeating: 0)
            defer {
                source.deinitialize(); source.deallocate()
                destination.deinitialize(); destination.deallocate()
            }
            let input = UnsafeBufferPointer(source)
            for _ in 0..<20 {
                var view = destination.mutableSpan
                try integrationScale(session, input.span, into: &view)
            }
            swift_mojo_probe_begin()
            for _ in 0..<1000 {
                var view = destination.mutableSpan
                try integrationScale(session, input.span, into: &view)
            }
            let allocations = swift_mojo_probe_end()
            precondition(destination.allSatisfy { $0 == 4 })
            print("elements=\(count) calls=1000 allocator_calls=\(allocations) positive_control=\(controlCount)")
            guard allocations == 0 else { throw ProbeError.invocationAllocated(allocations) }
        }
    }
}

private enum ProbeError: Error {
    case positiveControlFailed
    case invocationAllocated(UInt64)
}
