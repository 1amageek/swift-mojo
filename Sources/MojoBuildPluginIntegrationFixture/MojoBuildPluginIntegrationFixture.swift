import Mojo

@mojo
public func integrationAdd(_ a: Int32, _ b: Int32) -> Int32 {
  return a + b
}

@mojo(
  package: "SessionModel",
  function: "create_session",
  shutdown: "shutdown_session"
)
public func integrationOpenSession(
  _ requirements: MojoSessionRequirements
) throws -> MojoSessionOwner

@mojo(
  package: "SessionModel",
  function: "scale",
  sessionFactory: "integrationOpenSession"
)
public func integrationScale(
  _ session: MojoSessionOwner,
  _ input: [Float],
  into output: inout [Float]
) throws
