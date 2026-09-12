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
  let input: [Float] = [1, 2, 3]
  do {
    try input.withUnsafeBufferPointer { source in
      try output.withUnsafeMutableBufferPointer { destination in
        var span = destination.mutableSpan
        try integrationScale(session, source.span, into: &span)
      }
    }
  }
  #expect(output == [2, 4, 6])

  try session.shutdown()
  #expect(session.isShutdown)
  do {
    try input.withUnsafeBufferPointer { source in
      try output.withUnsafeMutableBufferPointer { destination in
        var span = destination.mutableSpan
        try integrationScale(session, source.span, into: &span)
      }
    }
    Issue.record("Closed session accepted a span")
  } catch { #expect(error as? MojoSessionError == .shutdown) }
  try session.shutdown()
}

@Test(.timeLimit(.minutes(1)))
func publicBindingBorrowsExistingMemory() throws {
  let session = try integrationOpenSession(.init(device: .cpu,
    requiredCapabilities: [.synchronousInvocation, .hostAccessibleMemory, .float32]))
  defer { do { try session.shutdown() } catch { Issue.record("Shutdown failed: \(error)") } }
  let input = UnsafeMutableBufferPointer<Float>.allocate(capacity: 3)
  let output = UnsafeMutableBufferPointer<Float>.allocate(capacity: 3)
  input.initialize(repeating: 2)
  output.initialize(repeating: 0)
  defer {
    input.deinitialize(); input.deallocate()
    output.deinitialize(); output.deallocate()
  }
  do {
    var span = output.mutableSpan
    try integrationScale(session, input.span, into: &span)
  }
  #expect(output.allSatisfy { $0 == 4 })
  #expect(input.allSatisfy { $0 == 2 })
}

@Test(.timeLimit(.minutes(1)), arguments: [0, 1, 3])
func publicBindingChecksBorrowOverlap(offset: Int) throws {
  let session = try integrationOpenSession(.init(device: .cpu,
    requiredCapabilities: [.synchronousInvocation, .hostAccessibleMemory, .float32]))
  defer { do { try session.shutdown() } catch { Issue.record("Shutdown failed: \(error)") } }
  let storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: 6)
  storage.initialize(repeating: 2)
  defer { storage.deinitialize(); storage.deallocate() }
  // Deliberately construct aliasing views to exercise the foreign-call gate.
  // All offsets stay inside the initialized allocation; no view escapes it.
  let input = UnsafeBufferPointer(start: storage.baseAddress!, count: 3)
  let output = UnsafeMutableBufferPointer(start: storage.baseAddress!.advanced(by: offset), count: 3)
  do {
    var span = output.mutableSpan
    try integrationScale(session, input.span, into: &span)
    #expect(offset == 3)
  } catch {
    #expect(offset < 3)
    #expect(error as? MojoInvocationError == .overlappingBuffers)
  }
  if offset < 3 { #expect(storage.allSatisfy { $0 == 2 }) }
  else { #expect(output.allSatisfy { $0 == 4 }) }
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

@Test(.timeLimit(.minutes(1)))
func publicNumericSpanBindingsExecuteMojo() throws {
  let source: [Float] = [1, 2, 3]
  let sum = try source.withUnsafeBufferPointer { try integrationSum($0.span) }
  #expect(sum == 6)
  let doubles = [1.25, -3.5, 1e100]
  var output = [Double](repeating: 0, count: doubles.count)
  try doubles.withUnsafeBufferPointer { input in
    try output.withUnsafeMutableBufferPointer { destination in
      var span = destination.mutableSpan
      try integrationScaleDouble(input.span, into: &span)
    }
  }
  #expect(output == [2.5, -7, 2e100])
  var shortOutput = [Double](repeating: 99, count: 1)
  var failureStatus: Int32?
  do {
    try doubles.withUnsafeBufferPointer { input in
      try shortOutput.withUnsafeMutableBufferPointer { destination in
        var span = destination.mutableSpan
        try integrationScaleDouble(input.span, into: &span)
      }
    }
  } catch let error as MojoInvocationError {
    guard case .invocationFailed(_, let status) = error else { throw error }
    failureStatus = status
  }
  #expect(failureStatus == 4)
  #expect(shortOutput == [99])
}
