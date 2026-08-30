import Foundation
import Mojo
import MojoArtifactCore
import MojoBuildPluginIntegrationFixture
import Testing

@Test(.timeLimit(.minutes(1)))
func buildPluginVerifiesLinksAndRunsPreparedMojoArtifact() throws {
  let attestation = try integrationStaticArtifactAttestation()
  let repeatedAttestation = try integrationStaticArtifactAttestation()
  #expect(attestation == repeatedAttestation)
  try verifyAttestationAgainstPreparedManifest(attestation)

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

private func verifyAttestationAgainstPreparedManifest(
  _ attestation: MojoStaticArtifactAttestation
) throws {
  let packageRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let manifestURL = packageRoot
    .appendingPathComponent("Generated/MojoBuildPluginIntegrationFixture")
    .appendingPathComponent("MojoArtifact.json")
  let manifest = try JSONDecoder().decode(
    MojoArtifactManifest.self,
    from: Data(contentsOf: manifestURL)
  )
  let identity = manifest.effectiveIdentity
  let slice = try #require(
    manifest.effectiveSlices.first {
      $0.target.triple == attestation.targetTriple
        && $0.target.cpu == attestation.targetCPU
        && $0.target.accelerator == attestation.targetAccelerator
    }
  )
  let adapter = try MojoNativeArtifactAdapter(target: slice.target)
  let artifact = try #require(
    manifest.effectiveArtifacts.first { $0.adapter == adapter }
  )

  #expect(attestation.schemaVersion == manifest.schemaVersion)
  #expect(attestation.abiVersion == manifest.abiVersion)
  #expect(attestation.compilerVersion == manifest.compilerVersion)
  #expect(
    attestation.generationPipelineDigest
      == manifest.generationPipelineDigest
  )
  #expect(attestation.targetName == identity.targetName)
  #expect(attestation.moduleName == identity.moduleName)
  #expect(attestation.sourceGraphDigest == manifest.sourceGraphDigest)
  #expect(
    attestation.sourceGraphIdentifier == manifest.sourceGraphIdentifier
  )
  #expect(attestation.inputGraphDigest == manifest.inputGraphDigest)
  #expect(
    attestation.inputGraphIdentifier == manifest.inputGraphIdentifier
  )
  #expect(
    attestation.generatedSourceDigest == manifest.generatedSourceDigest
  )
  #expect(attestation.sourceMapDigest == manifest.sourceMapDigest)
  #expect(attestation.artifactSetDigest == manifest.artifactDigest)
  #expect(attestation.nativeArtifactAdapter.rawValue == adapter.rawValue)
  #expect(attestation.nativeArtifactName == artifact.name)
  #expect(attestation.nativeArtifactDigest == artifact.digest)
  #expect(attestation.libraryIdentifier == slice.libraryIdentifier)
  #expect(attestation.archiveDigest == slice.archiveDigest)
  #expect(attestation.bindings.count == manifest.bindings.count)
  for (actual, expected) in zip(attestation.bindings, manifest.bindings) {
    #expect(actual.bindingID == expected.bindingID)
    #expect(actual.functionName == expected.functionName)
    #expect(actual.abiDigest == expected.abiDigest)
    #expect(actual.implementationDigest == expected.implementationDigest)
  }
#if arch(arm64) && os(macOS)
  #expect(attestation.targetTriple.lowercased().hasPrefix("arm64-"))
  #expect(attestation.targetTriple.lowercased().contains("-apple-macos"))
#endif
}
