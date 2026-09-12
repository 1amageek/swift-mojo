# ADR-0016: Direct Swift–Mojo execution

- Status: generic direct API qualified on Mac and Jetson; release and full Lume integration pending
- Date: 2026-09-12
- Parent: [package design](../DESIGN.md)

## Decision and authority

The user's subsequent instruction places MAX model loading, tensor management
and inference in Swift through MAX's official C API. These operations do not
require swift-mojo or a custom Mojo wrapper. This ADR governs generic custom
Mojo calls only; MAX session ownership is not forced through MojoSessionOwner.

The user's latest instruction replaces the worker-first resource migration.
Swift calls generated Mojo functions through C ABI in the same process. C ABI
specifies the calling convention; it does not require C implementation code.
Process isolation is a consumer responsibility, not the generic library's default.
ADR-0015 and the resource-worker target plans are historical for this migration.
ADR-0013's restriction to isolated consumers is superseded for this direct path;
its artifact identity and runtime-closure verification remain applicable.

```text
Swift owner -> scoped typed borrow -> generated C ABI call
                                        -> consumer's Mojo computation
Swift owner <- return after every reader/writer has completed
```

## Current implementation evidence

- `Sources/Mojo/MojoSessionOwner.swift` already provides synchronous session
  borrowing, exclusive admission, resource ownership and explicit shutdown.
- `Sources/MojoArtifactCore/MojoStaticSourceRenderer.swift` already emits Mojo
  C ABI exports and matching C declarations. These declarations contain no C
  processing implementation.
- ADR-0013 owns a separately callable library with an explicit runtime closure.
- Worker resource descriptors, FD transport and wire scalar encoding are not
  prerequisites for direct calls. Stop expanding that path for Lume.
- The native resource adapter's C consumer tests establish an ABI call, not a
  Swift/MAX/GPU lifecycle or the direct public API's performance.

## Responsibilities and invariants

swift-mojo owns generated typed calls, artifact/runtime identity, session and
buffer lifetime, and explicit failure. Lume owns models, MAX C API orchestration,
preprocessing, camera leases, scheduling, frame deadlines and display matching.
MAX owns model execution; custom Mojo kernels own their computation.
Reuse the existing session owner after verifying its actual direct execution path;
new parallel ownership or session abstractions require a demonstrated gap.

Arguments use native fixed-width C-compatible values and scoped typed pointers.
Keep source ownership through GPU completion on success and failure. No IPC,
FD transfer, wire serialization or worker-specific token is required by the direct
API. A pointer alone neither owns memory nor proves GPU completion.

Cancellation stops new work. An in-flight foreign call must finish/join its GPU
readers before releasing buffers or destroying the session. A deadline cannot
safely free a buffer still in use. Process termination as a hard deadline or crash
containment mechanism belongs to an explicitly isolated consumer deployment.
Mojo failures return explicit statuses; language exceptions do not cross C ABI.
A Mojo crash affects the Swift process; this is part of the selected boundary.

## Qualification and change impact

Before finalizing generic APIs, qualify Swift -> generated C ABI -> Mojo calls
with actual consumer computation, numerical comparison, synchronization, failure
and shutdown. Benchmark public calls with retained input. Lume separately owns
the direct MAX C API model lifecycle and capture-to-matched-display p95 <=100ms;
neither package may use the other's proof as a substitute for its own boundary.

After direct-path verification, remove superseded worker-only migration code and
update package, Mojo, ArtifactCore and Lume designs together. Preserve unrelated
worktrees and independent consumers until their actual call sites are reviewed.
Do not claim direct execution from old worker, Python or C-only qualification.

### Direct Jetson execution evidence

[Lume's direct fixture](../../Lume/Tests/Fixtures/DirectMAX/README.md), commit
`8cfd0ab`, runs Swift -> Mojo -> MAX in one process. It initializes both current
models, invokes the detector on GPU, matches 35 outputs byte-for-byte, recovers
from a missing-model initialization failure, rejects invalid extent/nonfinite
input, and destroys the session before exit 0. This removes the assumption that
MAX requires a worker for language interoperability. The fixture uses direct
borrowed pointers and C declarations, with no C processing implementation.
It does not yet qualify the generic public API, pose execution, cancellation,
RAW integration or capture-to-matched-display latency.

The same fixture directory now separately qualifies Swift -> official MAX C API
on Jetson, without the Mojo wrapper. Its README owns the exact scope and results;
that evidence establishes MAX interoperability, not generic swift-mojo API
performance. Host tensor staging remains a MAX transfer even with direct calls.
