import MojoArtifactCore
import MojoCompilerCore
import Testing

@Suite("Mojo runtime library loader policy")
struct MojoRuntimeLibraryLoaderPolicyTests {
    @Test(.timeLimit(.minutes(1)))
    func rejectsAnAmbientLoaderRoot() throws {
        let fixture = try Fixture()
        let inspection = fixture.inspection(
            runtimeSearchPaths: ["/opt/modular/lib"]
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeLoaderPolicy.validate(
                linkedLibrary: inspection,
                receipt: fixture.receipt,
                libraryName: "libSwiftMojo_Model_ABI.dylib",
                exportedSymbols: fixture.exportedSymbols
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsAnExportOutsideTheGeneratedABI() throws {
        let fixture = try Fixture()
        let inspection = fixture.inspection(
            exportedSymbols: fixture.exportedSymbols.union([
                "undeclared_entry_point",
            ])
        )

        #expect(throws: MojoArtifactError.self) {
            try MojoRuntimeLoaderPolicy.validate(
                linkedLibrary: inspection,
                receipt: fixture.receipt,
                libraryName: "libSwiftMojo_Model_ABI.dylib",
                exportedSymbols: fixture.exportedSymbols
            )
        }
    }
}

private struct Fixture {
    let receipt: MojoRuntimeDependencyReceipt
    let exportedSymbols: Set<String> = ["swift_mojo_model_create_session_v1"]

    init() throws {
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "apple-m4",
            accelerator: "metal:4"
        )
        receipt = MojoRuntimeDependencyReceipt(
            target: target,
            objectDigest: String(repeating: "a", count: 64),
            requiredSymbols: ["AsyncRT_fixture"],
            systemDependencies: ["/usr/lib/libSystem.B.dylib"],
            libraries: [
                .init(
                    fileName: "libRuntime.dylib",
                    digest: String(repeating: "b", count: 64),
                    architecture: "arm64",
                    installName: "@rpath/libRuntime.dylib",
                    dynamicDependencies: ["/usr/lib/libSystem.B.dylib"],
                    providedSymbols: ["AsyncRT_fixture"]
                ),
            ]
        )
    }

    func inspection(
        runtimeSearchPaths: [String] = ["@loader_path"],
        exportedSymbols: Set<String>? = nil
    ) -> MojoRuntimeBinaryInspection {
        MojoRuntimeBinaryInspection(
            architecture: "arm64",
            installName: "@rpath/libSwiftMojo_Model_ABI.dylib",
            dynamicDependencies: [
                "@rpath/libRuntime.dylib",
                "/usr/lib/libSystem.B.dylib",
            ],
            runtimeSearchPaths: runtimeSearchPaths,
            exportedSymbols: exportedSymbols ?? self.exportedSymbols
        )
    }
}
