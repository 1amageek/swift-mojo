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


@mojo(package: "SessionModel", function: "create_resource", shutdown: "destroy_resource",
      synchronize: "synchronize_resources", sessionFactory: "integrationOpenSession")
public func integrationCreateResource(_ session: MojoSessionOwner, _ config: borrowing Span<UInt8>) throws -> MojoSessionResourceOwner

@mojo(package: "SessionModel", function: "create_resource", shutdown: "destroy_resource",
      synchronize: "synchronize_resources", sessionFactory: "integrationOpenSession")
public func integrationCreateOtherResource(_ session: MojoSessionOwner, _ config: borrowing Span<UInt8>) throws -> MojoSessionResourceOwner

@mojo(package: "SessionModel", function: "sum_resources", synchronize: "synchronize_resources",
      sessionFactory: "integrationOpenSession", resourceFactory: "integrationCreateResource")
public func integrationSumResources(_ session: MojoSessionOwner, _ resources: borrowing Span<MojoSessionResourceOwner>) throws

@mojo(package: "SessionModel", function: "check_resources", synchronize: "synchronize_resources",
      sessionFactory: "integrationOpenSession", resourceFactory: "integrationCreateResource")
public func integrationCheckResources(_ session: MojoSessionOwner, _ resources: borrowing Span<MojoSessionResourceOwner>) throws

@mojo(package: "SessionModel", function: "fail_resources", synchronize: "synchronize_resources",
      sessionFactory: "integrationOpenSession", resourceFactory: "integrationCreateResource")
public func integrationFailResources(_ session: MojoSessionOwner, _ resources: borrowing Span<MojoSessionResourceOwner>) throws

@mojo(package: "SessionModel", function: "check_resource_count", synchronize: "synchronize_resources",
      sessionFactory: "integrationOpenSession", resourceFactory: "integrationCreateResource")
public func integrationCheckResourceCount(_ session: MojoSessionOwner, _ resources: borrowing Span<MojoSessionResourceOwner>) throws
