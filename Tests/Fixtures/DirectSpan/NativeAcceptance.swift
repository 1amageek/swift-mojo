import Mojo

@main
struct NativeAcceptance {
    static func main() throws {
        let attestation = try integrationStaticArtifactAttestation()
        #if os(Linux)
        precondition(attestation.targetTriple == "aarch64-unknown-linux-gnu")
        #endif
        precondition(integrationAdd(20, 22) == 42)
        let floats: [Float] = [1, 2, 3]
        let sum = try floats.withUnsafeBufferPointer { try integrationSum($0.span) }
        precondition(sum == 6)
        let doubles = [1.25, -3.5, 1e100]
        var doubled = [Double](repeating: 0, count: 3)
        try doubles.withUnsafeBufferPointer { input in
            try doubled.withUnsafeMutableBufferPointer { destination in
                var span = destination.mutableSpan
                try integrationScaleDouble(input.span, into: &span)
            }
        }
        precondition(doubled == [2.5, -7, 2e100])
        let session = try integrationOpenSession(.init(device: .cpu,
            requiredCapabilities: [.synchronousInvocation, .hostAccessibleMemory, .float32]))
        let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: 6)
        storage.initialize(repeating: 2)
        defer { storage.deinitialize(); storage.deallocate() }
        // One initialized allocation owns both views until each synchronous call
        // returns. The adjacent case is disjoint; other cases test admission.
        let input = UnsafeBufferPointer(start: storage.baseAddress!, count: 3)
        for offset in [0, 1, 3] {
            let output = UnsafeMutableBufferPointer(start: storage.baseAddress!.advanced(by: offset), count: 3)
            do {
                var span = output.mutableSpan
                try integrationScale(session, input.span, into: &span)
                precondition(offset == 3)
            } catch let error as MojoInvocationError {
                precondition(offset < 3 && error == .overlappingBuffers)
                precondition(storage.allSatisfy { $0 == 2 })
            }
        }
        precondition(storage.prefix(3).allSatisfy { $0 == 2 })
        precondition(storage.suffix(3).allSatisfy { $0 == 4 })
        try session.shutdown()
        var rejectedClosedSession = false
        do {
            let output = UnsafeMutableBufferPointer(start: storage.baseAddress!.advanced(by: 3), count: 3)
            var span = output.mutableSpan
            try integrationScale(session, input.span, into: &span)
        } catch let error as MojoSessionError {
            precondition(error == .shutdown)
            rejectedClosedSession = true
        }
        precondition(rejectedClosedSession)
        try session.shutdown()
        print("Public Span binding: native macro, artifact identity, scalar, disjoint output, overlap rejection and shutdown passed")
    }
}
