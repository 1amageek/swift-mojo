import Mojo
import Testing

@Suite("Mojo device abstraction")
struct MojoDeviceKindTests {
    @Test(.timeLimit(.minutes(1)))
    func exposesExecutionClassesInsteadOfPlatformBackends() {
        #expect(MojoDeviceKind.allCases == [.cpu, .accelerator])
        #expect(MojoDeviceKind.cpu.rawValue == 0)
        #expect(MojoDeviceKind.accelerator.rawValue == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func acceleratorRequirementsMatchAcceleratorCapabilities() {
        let requirements = MojoSessionRequirements(
            device: .accelerator,
            requiredCapabilities: [.synchronousInvocation, .deviceMemory]
        )
        let capabilities = MojoSessionCapabilities(
            device: .accelerator,
            ordinal: 0,
            availableCapabilities: [
                .synchronousInvocation,
                .deviceMemory,
                .float32,
            ]
        )

        #expect(capabilities.satisfies(requirements))
    }
}
