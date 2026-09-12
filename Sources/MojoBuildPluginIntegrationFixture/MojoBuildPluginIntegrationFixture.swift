import Mojo

@mojoStaticArtifactAttestation
public func integrationStaticArtifactAttestation()
  throws -> MojoStaticArtifactAttestation

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
  _ input: borrowing Span<Float>,
  into output: inout MutableSpan<Float>
) throws

@mojo(package: "SessionModel", function: "sum_values")
public func integrationSum(_ values: borrowing Span<Float>) throws -> Float

@mojo(package: "SessionModel", function: "scale_double")
public func integrationScaleDouble(
  _ input: borrowing Span<Double>,
  into output: inout MutableSpan<Double>
) throws
