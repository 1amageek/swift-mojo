@_spi(SwiftMojoGenerated)
public struct MojoStaticArtifactPreflight: Sendable {
    private let validationError: MojoInvocationError?

    public init(
        expectedABIVersion: UInt32,
        actualABIVersion: () -> UInt32,
        expectedInputGraphIdentifier: UInt64,
        actualInputGraphIdentifier: () -> UInt64,
        bindingIDs: [UInt64],
        hasBinding: (UInt64) -> Bool
    ) {
        let actualABIVersion = actualABIVersion()
        if actualABIVersion != expectedABIVersion {
            self.validationError = .incompatibleStaticABI(
                expected: expectedABIVersion,
                actual: actualABIVersion
            )
            return
        }
        let actualInputGraphIdentifier = actualInputGraphIdentifier()
        if actualInputGraphIdentifier != expectedInputGraphIdentifier {
            self.validationError = .inputGraphMismatch(
                expected: expectedInputGraphIdentifier,
                actual: actualInputGraphIdentifier
            )
            return
        }
        if let missingBindingID = bindingIDs.first(where: {
            !hasBinding($0)
        }) {
            self.validationError = .bindingUnavailable(
                bindingID: missingBindingID
            )
        } else {
            self.validationError = nil
        }
    }

    @inline(__always)
    public func validatedAttestation(
        _ attestation: MojoStaticArtifactAttestation
    ) throws
        -> MojoStaticArtifactAttestation {
        try requireValid()
        return attestation
    }

    @inline(__always)
    public func requireValid() throws {
        if let validationError {
            throw validationError
        }
    }

    @inline(__always)
    public func withValidatedArtifact<Result>(
        _ operation: () throws -> Result
    ) throws -> Result {
        try requireValid()
        return try operation()
    }
}
