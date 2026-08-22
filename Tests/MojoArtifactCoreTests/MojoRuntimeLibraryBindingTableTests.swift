import MojoArtifactCore
import Testing

@Suite("Mojo runtime library binding table")
struct MojoRuntimeLibraryBindingTableTests {
    @Test(.timeLimit(.minutes(1)))
    func sortsAndValidatesSessionFactoryRelationships() throws {
        let validated = try MojoRuntimeLibraryBindingTable.validated([
            .init(
                bindingID: 2,
                functionName: "executeBatch",
                signature: "sessionBorrowedMutableFloat32Buffers",
                sessionFactoryFunctionName: "createSession"
            ),
            .init(
                bindingID: 1,
                functionName: "createSession",
                signature: "runtimeSessionFactory"
            ),
        ])

        #expect(validated.map(\.bindingID) == [1, 2])
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsMissingSessionFactory() {
        #expect(throws: MojoRuntimeLibraryBindingTable.ValidationError.self) {
            try MojoRuntimeLibraryBindingTable.validated([
                .init(
                    bindingID: 2,
                    functionName: "executeBatch",
                    signature: "sessionBorrowedMutableFloat32Buffers",
                    sessionFactoryFunctionName: "createSession"
                ),
            ])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsFactoryMetadataOnStatelessBinding() {
        #expect(throws: MojoRuntimeLibraryBindingTable.ValidationError.self) {
            try MojoRuntimeLibraryBindingTable.validated([
                .init(
                    bindingID: 1,
                    functionName: "add",
                    signature: "int32Binary",
                    sessionFactoryFunctionName: "createSession"
                ),
            ])
        }
    }
}
