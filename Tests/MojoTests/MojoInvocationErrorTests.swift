import Mojo
import Testing

@Suite("Mojo invocation errors")
struct MojoInvocationErrorTests {
    @Test(.timeLimit(.minutes(1)))
    func preservesFailureContext() {
        #expect(
            MojoInvocationError.incompatibleStaticABI(
                expected: 1,
                actual: 2
            )
                != MojoInvocationError.inputGraphMismatch(
                    expected: 1,
                    actual: 2
                )
        )
        #expect(
            MojoInvocationError.bindingUnavailable(bindingID: 42)
                == .bindingUnavailable(bindingID: 42)
        )
        #expect(
            MojoInvocationError.emptyBorrowedBuffer.description
                .contains("non-empty")
        )
    }
}
