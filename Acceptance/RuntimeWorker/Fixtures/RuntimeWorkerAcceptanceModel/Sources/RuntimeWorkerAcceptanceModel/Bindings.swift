import Mojo

@mojo(
    package: "RuntimeWorkerAcceptanceModel",
    function: "create_session",
    shutdown: "shutdown_session"
)
public func createSession(
    _ requirements: MojoSessionRequirements
) throws -> MojoSessionOwner

@mojo(
    package: "RuntimeWorkerAcceptanceModel",
    function: "scale",
    sessionFactory: "createSession"
)
public func scale(
    _ session: MojoSessionOwner,
    _ input: [Float],
    into output: inout [Float]
) throws

@mojo(
    package: "RuntimeWorkerAcceptanceModel",
    function: "stall",
    sessionFactory: "createSession"
)
public func stall(
    _ session: MojoSessionOwner,
    _ input: [Float],
    into output: inout [Float]
) throws
