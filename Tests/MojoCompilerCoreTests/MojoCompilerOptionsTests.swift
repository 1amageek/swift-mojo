import Testing
@testable import MojoCompilerCore

@Test(.timeLimit(.minutes(1)))
func rejectsUnsafeTargetValue() {
    #expect(throws: MojoCompilerToolError.self) {
        _ = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx;touch",
            cpu: "apple-m1"
        )
    }
}

@Test(.timeLimit(.minutes(1)))
func preservesValidatedTargetAndCompilerArguments() throws {
    let target = try MojoTargetConfiguration(
        triple: "arm64-apple-macosx14.0",
        cpu: "apple-m1"
    )

    #expect(target.triple == "arm64-apple-macosx14.0")
    #expect(target.cpu == "apple-m1")
    #expect(target.compilerArguments == [
        "--target-triple", "arm64-apple-macosx14.0",
        "--target-cpu", "apple-m1",
    ])
}
