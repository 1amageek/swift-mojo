# Mojo

## Direct-call completion work (2026-09-12)

The current task completes generic Swift/Mojo calls before resuming consumer
integration. The public borrowed host-memory boundary will use standard-library
`borrowing Span<Element>` and `inout MutableSpan<Element>` instead of mandatory
Array inputs/outputs. Arrays and caller-owned contiguous memory supply these
views; the bridge must not materialize their payloads. The initially admitted
scalar types and generated signature grammar must be explicitly enumerated and
validated by BindingCore before implementation is considered complete.

```text
caller storage -> scoped Span / MutableSpan -> generated C ABI -> Mojo function
session/resource owner -> admitted opaque handles -----------^
                     return only after all foreign readers/writers complete
```

Mutable-output bindings require disjoint input/output byte ranges. The generated
registry rejects complete or partial overlap before the Mojo call; adjacent
ranges are allowed. Extent and address addition use checked arithmetic. In-place
algorithms require an explicitly mutable-only contract, not an immutable alias.
`MojoBuildPluginIntegrationTests.publicBindingChecksBorrowOverlap` owns the real
Mojo/public-call success and rejection evidence for this boundary.

Span is host-accessible storage, not a device pointer wrapper. Device resources
retain their session, memory-location metadata and destructor through the
existing owners. Generated resource calls must borrow all participating
resources under one session admission; nesting individual borrows currently
fails with `busy` and is not a valid multi-resource implementation. Domain,
shutdown, aliasing and exactly-once destruction remain explicit contracts.
No MAX model, image format, frame identity, retry or deadline policy belongs
here. Do not introduce a second resource owner or asynchronous completion API
merely to replace the existing synchronous foreign-call boundary.

The current completion target is synchronous: every generated call returns only
after its authored Mojo operation has stopped using borrowed storage, including
GPU readers/writers. Shutdown during a borrow must fail explicitly rather than
freeing active resources. Consumer cancellation may stop later calls, but cannot
revoke an active synchronous borrow. Arbitrary foreign implementations must
honor this boundary; types alone cannot prove their device completion behavior.

The admitted static host signatures are Int32 binary addition, readonly
`Span<Float>` reduction, Float32/Float64 input-to-mutable-output calls, and
session-bound Float32 input/output calls. Existing session and Float32 resource
factories remain available; their host transfers now take Span/MutableSpan.
Other type/signature combinations fail binding validation. General multi-resource
operation generation follows the factory-provenanced contract below. The worker
resource-token declaration remains separate from this direct API.

### Direct opaque resources

The admitted factory takes a session and a borrowed byte configuration and returns
`MojoSessionResourceOwner`. The operation takes a session and a borrowed span of
resource owners. Its `resourceFactory` attribute identifies the exact producing
factory; every participant must have that identity and the same session instance.
An operation may accept any number of resources of that factory. Payload layout,
resource roles and device allocation remain the authored Mojo implementation's
responsibility. No untyped pointer is exposed to application callers.

Generated adapters validate factory identity, session identity, liveness and
unique resource IDs before acquiring one exclusive session lease. Duplicate
resources are rejected because these operations permit mutation. A scoped array
of pointer metadata is passed through C ABI; resource payloads are not copied.
The temporary metadata may allocate for large argument counts. No zero-allocation
claim is made without the corresponding argument-count measurement.

Factory and operation adapters invoke their declared synchronizer on every status.
A failed factory destroys any returned partial resource after synchronization.
The first operation/create failure wins over a subsequent synchronization failure.
A synchronizer must finish all uses even when it returns an error. Destruction
and foreign calls execute outside the session mutex. Single-resource and aggregate
borrows share the same admission and deferred-destruction state.

The ownership implementation and synchronization primitive are identical on all
supported native targets. WASM/Embedded are not supported prepared Mojo targets;
this change adds no conditional storage or Sendable contract. Tests must reject
wrong factory, different session instance, duplicates, closed resources and busy
admission without invoking foreign code; also prove release after throwing calls.
Actual macro-to-Mojo and direct-dispatcher benchmarks on Mac and Jetson own the
completion evidence, including failed calls followed by successful calls. The
ResourceBenchmark acceptance checks those paths before collecting measurements.

Actual macro-to-Mojo execution was verified on Mac Swift 6.4.2-dev
`d2e983b81b18217` and native Jetson Swift 6.4-dev `424cae54c1a10da`.
[Native acceptance](../../Tests/Fixtures/DirectSpan/NativeAcceptance.swift) checks
Float32 reduction, Float64 output, session mutation, alias rejection, and shutdown.
The standalone local-session acceptance additionally checks owned resource
creation, exact-count transfer, all failure statuses, and failure-time completion;
its same public consumer passed on native Jetson. Swift-side Address Sanitizer
passed on Mac; this does not instrument the Mojo implementation.
[Benchmarks](../../Benchmarks/RuntimeBridge/README.md) own timing and observed
allocation evidence. No GPU or Lume performance claim follows from these tests.

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

Host transfer methods on `MojoFloat32Buffer` use the same scoped `Span<Float>`
and `MutableSpan<Float>` contract as direct function bindings. Transfer bytes
are deliberately copied by the selected foreign implementation; the Swift
boundary does not materialize an array. Count validation precedes resource
admission, and the foreign transfer completes before either view expires.
