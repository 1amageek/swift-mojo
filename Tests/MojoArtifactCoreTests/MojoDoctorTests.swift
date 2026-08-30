import MojoArtifactCore
import MojoCompilerCore
import Testing

#if os(Linux)
private struct LinuxDoctorProcessRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath != "/usr/bin/xcrun" else {
            throw MojoArtifactError.invalidArguments(
                "Linux doctor must not invoke xcrun"
            )
        }
        return MojoProcessResult(status: 0, output: "tool fixture")
    }
}

@Test(.timeLimit(.minutes(1)))
func linuxDoctorChecksTheNativeToolchainAndReportsConsumerOnlyMode() {
    let report = MojoDoctor(
        environment: ["SWIFT_MOJO_EXECUTABLE": "/usr/bin/true"],
        processRunner: LinuxDoctorProcessRunner()
    ).diagnose()

    #expect(
        report.checks.map(\.name)
            == [
                "Swift toolchain",
                "Static artifact authoring host",
                "Mojo compiler",
            ]
    )
    #expect(report.checks[0].status == .passed)
    #expect(report.checks[1].status == .failed)
    #expect(report.checks[2].status == .passed)
}
#endif
