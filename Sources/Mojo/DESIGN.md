# Mojo

## Purpose and Scope

`Mojo` is the public Swift module of the `swift-mojo` package. Its parent is the
[package design](../../DESIGN.md). It has no child design units.

The module owns the application-facing macro declarations, immutable static
artifact attestation value, invocation errors, and generic session/buffer
ownership contracts. It does not own artifact preparation, filesystem
verification, model semantics, device policy, or deployment policy.

## Responsibilities and Boundaries

The module exposes `@mojo` for prepared function bindings and
`@mojoStaticArtifactAttestation`
for a target-local function that returns the attestation embedded by the
generated Registry. Only generated code imports the construction SPI for the
attestation and preflight value. Application code can inspect the returned
immutable value but cannot construct a trusted value through the public API.

The attestation records verified manifest and selected native-slice facts. It
does not establish that a device exists, that a session was created, or that a
kernel executed. Those facts require a separate consuming-package runtime
probe and behavioral evidence.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`swift-mojo`](../../DESIGN.md) | parent | Static-first prepare, build verification, generated Registry | Owns the artifact pipeline that supplies the values embedded here. | Any field addition changes the Registry generation pipeline and must re-verify prepared artifacts. |
| [ADR-0014](../../docs/ADR-0014-STATIC-ARTIFACT-ATTESTATION.md) | coordinates with | Attestation and preflight decision | Defines why the public access path is generated and static. | Do not replace it with runtime manifest reads or dynamic symbol loading. |

## Architecture

```text
MojoBuildPlugin verification
    -> generated __SwiftMojoGeneratedBindings
        -> linked ABI/input graph/all-binding preflight
            -> @mojoStaticArtifactAttestation function
                -> immutable MojoStaticArtifactAttestation
```

The generated Registry is target-internal. The macro is the stable public
authoring surface, so consumers do not name generated implementation symbols.

## Contracts and Invariants

- Attestation construction is available only through
  `SwiftMojoGenerated` SPI.
- `@mojoStaticArtifactAttestation` accepts one bodyless file-scope,
  synchronous, throwing, parameterless
  function returning `MojoStaticArtifactAttestation` and replaces its body with
  a generated Registry call.
- The Registry returns an attestation only after the actual linked ABI version,
  input-graph identifier, and every prepared binding ID match the embedded
  verified values.
- Every attestation field is copied from the verified manifest, its effective
  artifact identity, the compile-destination slice, or the manifest binding
  records. Runtime filesystem reads and value re-derivation are forbidden.
- The selected slice is compile-destination-specific and identifies target
  triple, CPU, optional accelerator, library identifier, and archive digest.
- Validation failure occurs before any scalar, buffer, or session dispatcher
  invokes its linked operation.

## Runtime Flows

```text
application calls declared @mojoStaticArtifactAttestation function
    -> generated Registry evaluates one thread-safe static preflight
       -> ABI mismatch: typed failure
       -> input graph mismatch: typed failure
       -> first missing binding: typed failure
       -> otherwise return embedded immutable attestation
```

Normal `@mojo` dispatchers use the same cached preflight. A session factory is
therefore unreachable when that preflight failed.

## State, Ownership, and Lifecycle

Attestation and preflight values are immutable `Sendable` structs. Swift static
initialization owns the one cached validation result for the process image.
Static artifacts follow process-image lifetime. Session and buffer lifetime
remain owned by their existing explicit owner types and are not extended by an
attestation.

## Failure, Concurrency, and Constraints

Swift's thread-safe static initialization evaluates the linked identity and
membership calls once per generated Registry. Validation stores only an
immutable typed error or success value. It performs no I/O, allocation of model
state, session creation, or device work. Unsupported legacy manifests fail the
attestation access explicitly; invocation compatibility remains unchanged.

## Verification and Change Impact

Verification must cover macro signature diagnostics, exact field projection
from a verified manifest and selected slice, actual integration access through
the generated Registry, and preflight rejection before an operation closure is
entered for ABI, input-graph, and arbitrary binding mismatch. Registry changes
must bump the generation-pipeline version, regenerate the integration fixture,
and rerun package and build-plugin integration tests.

Changes to attestation fields or validation order require review of the package
master design, generated Registry writer, build verifier, macro tests, public
value tests, and the real static-link integration fixture.
