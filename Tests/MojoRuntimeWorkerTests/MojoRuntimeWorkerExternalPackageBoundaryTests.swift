import Foundation
import MojoCompilerCore
import Testing

@Suite("External package runtime boundary")
struct MojoRuntimeWorkerExternalPackageBoundaryTests {
    @Test(.timeLimit(.minutes(5)))
    func productsExposeTypedModulesWithoutRawPOSIXCalls() throws {
        let fixture = try ExternalRuntimeBoundaryFixture()
        defer { fixture.remove() }

        let runner = FoundationMojoProcessRunner(timeoutSeconds: 60)

        let runtimeTyped = try fixture.build(
            target: "RuntimeTyped",
            runner: runner
        )
        #expect(
            runtimeTyped.status == 0,
            Comment(rawValue: runtimeTyped.output)
        )

        let workerTyped = try fixture.build(
            target: "WorkerTyped",
            runner: runner
        )
        #expect(
            workerTyped.status == 0,
            Comment(rawValue: workerTyped.output)
        )

        let runtimeRaw = try fixture.build(
            target: "RuntimeRaw",
            runner: runner
        )
        #expect(runtimeRaw.status != 0)
        for symbol in [
            "swift_mojo_posix_spawn",
            "swift_mojo_posix_close_file",
            "swift_mojo_posix_signal_group",
            "swift_mojo_posix_wait_nohang",
            "swift_mojo_posix_exit",
        ] {
            #expect(
                runtimeRaw.output.contains(symbol),
                "Missing compiler rejection for \(symbol)"
            )
        }

        let workerRaw = try fixture.build(
            target: "WorkerRaw",
            runner: runner
        )
        #expect(workerRaw.status != 0)
        for symbol in [
            "swift_mojo_posix_worker_spawn",
            "swift_mojo_posix_worker_poll",
            "swift_mojo_posix_worker_read",
            "swift_mojo_posix_worker_write",
            "swift_mojo_posix_signal_group",
            "swift_mojo_posix_wait_nohang",
            "swift_mojo_posix_exit",
        ] {
            #expect(
                workerRaw.output.contains(symbol),
                "Missing compiler rejection for \(symbol)"
            )
        }
    }
}

private final class ExternalRuntimeBoundaryFixture {
    private let rootURL: URL

    init() throws {
        let fileManager = FileManager.default
        rootURL = fileManager.temporaryDirectory.appendingPathComponent(
            "swift-mojo-public-boundary-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )

        let repositoryURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try write(
            """
            // swift-tools-version: 6.2

            import PackageDescription

            let package = Package(
                name: "ExternalRuntimeBoundary",
                platforms: [.macOS(.v15)],
                dependencies: [
                    .package(path: \(String(reflecting: repositoryURL.path))),
                ],
                targets: [
                    .target(
                        name: "RuntimeTyped",
                        dependencies: [
                            .product(
                                name: "MojoRuntime",
                                package: "swift-mojo"
                            ),
                        ]
                    ),
                    .target(
                        name: "WorkerTyped",
                        dependencies: [
                            .product(
                                name: "MojoRuntimeWorker",
                                package: "swift-mojo"
                            ),
                        ]
                    ),
                    .target(
                        name: "RuntimeRaw",
                        dependencies: [
                            .product(
                                name: "MojoRuntime",
                                package: "swift-mojo"
                            ),
                        ]
                    ),
                    .target(
                        name: "WorkerRaw",
                        dependencies: [
                            .product(
                                name: "MojoRuntimeWorker",
                                package: "swift-mojo"
                            ),
                        ]
                    ),
                ]
            )
            """,
            relativePath: "Package.swift"
        )
        try write(
            """
            import MojoRuntime

            public func acceptRuntimeProjection(
                _ value: MojoRuntimeWorkerBundleVerification
            ) {
                _ = value.schemaVersion
            }
            """,
            relativePath: "Sources/RuntimeTyped/RuntimeTyped.swift"
        )
        try write(
            """
            import MojoRuntimeWorker

            public func acceptRuntimeWorker(_ value: MojoRuntimeWorker) {
                _ = value
            }
            """,
            relativePath: "Sources/WorkerTyped/WorkerTyped.swift"
        )
        try write(
            """
            import CMojoPOSIXSupport
            import MojoRuntime

            public func callRawRuntimePOSIX() {
                var processID: Int32 = 0
                var waitStatus: Int32 = 0
                var errorCode: Int32 = 0
                _ = swift_mojo_posix_spawn(
                    nil,
                    nil,
                    nil,
                    -1,
                    &processID,
                    &errorCode
                )
                _ = swift_mojo_posix_close_file(-1, &errorCode)
                _ = swift_mojo_posix_signal_group(
                    processID,
                    15,
                    &errorCode
                )
                _ = swift_mojo_posix_wait_nohang(
                    processID,
                    &waitStatus,
                    &errorCode
                )
                swift_mojo_posix_exit(0)
            }
            """,
            relativePath: "Sources/RuntimeRaw/RuntimeRaw.swift"
        )
        try write(
            """
            import CMojoPOSIXSupport
            import MojoRuntimeWorker

            public func callRawWorkerPOSIX() {
                var protocolDescriptor: Int32 = -1
                var diagnosticDescriptor: Int32 = -1
                var processID: Int32 = 0
                var waitStatus: Int32 = 0
                var eventMask: Int32 = 0
                var errorCode: Int32 = 0
                var byte: UInt8 = 0
                _ = swift_mojo_posix_worker_spawn(
                    nil,
                    nil,
                    nil,
                    &protocolDescriptor,
                    &diagnosticDescriptor,
                    &processID,
                    &errorCode
                )
                _ = swift_mojo_posix_worker_poll(
                    protocolDescriptor,
                    diagnosticDescriptor,
                    -1,
                    1,
                    0,
                    &eventMask,
                    &errorCode
                )
                _ = swift_mojo_posix_worker_read(
                    protocolDescriptor,
                    &byte,
                    1,
                    &errorCode
                )
                _ = swift_mojo_posix_worker_write(
                    protocolDescriptor,
                    &byte,
                    1,
                    &errorCode
                )
                _ = swift_mojo_posix_signal_group(
                    processID,
                    15,
                    &errorCode
                )
                _ = swift_mojo_posix_wait_nohang(
                    processID,
                    &waitStatus,
                    &errorCode
                )
                swift_mojo_posix_exit(0)
            }
            """,
            relativePath: "Sources/WorkerRaw/WorkerRaw.swift"
        )
    }

    func build(
        target: String,
        runner: FoundationMojoProcessRunner
    ) throws -> MojoProcessResult {
        try runner.capture(
            executablePath: "/usr/bin/xcrun",
            arguments: [
                "swift",
                "build",
                "--package-path", rootURL.path,
                "--target", target,
                "--disable-sandbox",
            ]
        )
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: rootURL)
        } catch {
            Issue.record(
                "Failed to remove external boundary fixture: \(error)"
            )
        }
    }

    private func write(
        _ contents: String,
        relativePath: String
    ) throws {
        let fileURL = rootURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(
            to: fileURL,
            atomically: true,
            encoding: .utf8
        )
    }
}
