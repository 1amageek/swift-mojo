import Foundation
import MojoArtifactCore
import MojoCompilerCore
import Testing

private struct LinuxArchiveFixtureRunner: MojoProcessRunning {
    let expectedExecutablePath: String
    let expectedPrefix: [String]

    init(
        expectedExecutablePath: String = "/usr/bin/xcrun",
        expectedPrefix: [String] = ["llvm-ar"]
    ) {
        self.expectedExecutablePath = expectedExecutablePath
        self.expectedPrefix = expectedPrefix
    }

    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == expectedExecutablePath,
              arguments.starts(with: expectedPrefix) else {
            throw MojoArtifactError.invalidArguments(
                "Linux archiver command does not match the contract"
            )
        }
        let archiveArguments = Array(arguments.dropFirst(expectedPrefix.count))
        if archiveArguments.count == 3,
           archiveArguments[0] == "rcs" {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: archiveArguments[2]),
                to: URL(fileURLWithPath: archiveArguments[1])
            )
            return MojoProcessResult(status: 0, output: "")
        }
        if archiveArguments.count == 2,
           archiveArguments[0] == "t" {
            return MojoProcessResult(status: 0, output: "Bindings.o\n")
        }
        throw MojoArtifactError.invalidArguments(
            "Unexpected llvm-ar arguments: \(arguments)"
        )
    }
}

private struct EmptyArchiveFixtureRunner: MojoProcessRunning {
    func capture(
        executablePath: String,
        arguments: [String]
    ) throws -> MojoProcessResult {
        guard executablePath == "/usr/bin/ar" else {
            throw MojoArtifactError.invalidArguments(
                "Unexpected executable: \(executablePath)"
            )
        }
        if arguments.count == 3, arguments[0] == "rcs" {
            try Data("!<arch>\n".utf8).write(
                to: URL(fileURLWithPath: arguments[1])
            )
            return MojoProcessResult(status: 0, output: "")
        }
        if arguments.count == 2, arguments[0] == "-t" {
            return MojoProcessResult(status: 0, output: "")
        }
        throw MojoArtifactError.invalidArguments(
            "Unexpected ar arguments: \(arguments)"
        )
    }
}

@Suite("Mojo static archive construction")
struct MojoStaticArchiveBuilderTests {
    @Test(.timeLimit(.minutes(1)))
    func usesLLVMArchiverForLinuxELFObjects() throws {
        let fixture = try Fixture()
        let target = try MojoTargetConfiguration(
            triple: "aarch64-unknown-linux-gnu",
            cpu: "generic"
        )

        try MojoStaticArchiveBuilder(
            processRunner: LinuxArchiveFixtureRunner()
        ).build(
            objectURL: fixture.objectURL,
            archiveURL: fixture.archiveURL,
            target: target
        )

        #expect(FileManager.default.fileExists(atPath: fixture.archiveURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func usesTheConfiguredAbsoluteLLVMArchiver() throws {
        let fixture = try Fixture()
        let target = try MojoTargetConfiguration(
            triple: "aarch64-unknown-linux-gnu",
            cpu: "generic"
        )
        let archiver = "/opt/swift/usr/bin/llvm-ar"

        try MojoStaticArchiveBuilder(
            processRunner: LinuxArchiveFixtureRunner(
                expectedExecutablePath: archiver,
                expectedPrefix: []
            ),
            environment: ["SWIFT_MOJO_LLVM_AR": archiver]
        ).build(
            objectURL: fixture.objectURL,
            archiveURL: fixture.archiveURL,
            target: target
        )

        #expect(FileManager.default.fileExists(atPath: fixture.archiveURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func rejectsAnArchiveWithoutTheCompiledObjectMember() throws {
        let fixture = try Fixture()
        let target = try MojoTargetConfiguration(
            triple: "arm64-apple-macosx14.0",
            cpu: "generic"
        )

        #expect(
            throws: MojoArtifactError.staticArchiveMissingObject(
                target: target.identity,
                object: "Bindings.o"
            )
        ) {
            try MojoStaticArchiveBuilder(
                processRunner: EmptyArchiveFixtureRunner()
            ).build(
                objectURL: fixture.objectURL,
                archiveURL: fixture.archiveURL,
                target: target
            )
        }
    }
}

private struct Fixture {
    let archiveURL: URL
    let objectURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        objectURL = root.appendingPathComponent("Bindings.o")
        archiveURL = root.appendingPathComponent("libBindings.a")
        try Data("fixture object".utf8).write(to: objectURL)
    }
}
