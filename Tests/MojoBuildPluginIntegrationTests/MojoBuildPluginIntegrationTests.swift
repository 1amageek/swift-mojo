import Mojo
import MojoBuildPluginIntegrationFixture
import Testing

@Test(.timeLimit(.minutes(1)))
func buildPluginVerifiesLinksAndRunsPreparedMojoArtifact() throws {
  #expect(integrationAdd(20, 22) == 42)

  let session = try integrationOpenSession(
    MojoSessionRequirements(
      device: .cpu,
      requiredCapabilities: [
        .synchronousInvocation,
        .hostAccessibleMemory,
        .float32,
      ]
    )
  )
  var output = [Float](repeating: 0, count: 3)
  try integrationScale(session, [1, 2, 3], into: &output)
  #expect(output == [2, 4, 6])

  try session.shutdown()
  #expect(session.isShutdown)
  #expect(throws: MojoSessionError.shutdown) {
    try integrationScale(session, [1], into: &output)
  }
  try session.shutdown()
}
