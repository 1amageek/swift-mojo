# MojoRuntime

## Resource-worker verification delta (target design, 2026-09-12)

Project the immutable binding schemas, bounds and required transfer capabilities
from the next closed worker manifest defined by
[ArtifactCore](../MojoArtifactCore/DESIGN.md#resource-binding-generation-delta-target-design-2026-09-12).
Reject old/mixed versions or unknown records rather than adapting them.
Remain a read-only verifier: no resource import, mmap, device query or worker
launch here. A verified shared-input declaration is not host capability evidence.
Worker compares actual endpoint capability and schema identity before admitting
an invocation. Cross-level tests alter each projected field independently and
prove rejection before factory/invocation.


## Purpose and Scope

`MojoRuntime` is the public read-only verification module for deployed runtime
artifacts. Its parent is [`DESIGN.md`](../../DESIGN.md). It has no child
component designs.

It verifies ADR-0011 executable bundles, ADR-0013 callable-library bundles, and
the ADR-0015 W2 direct-linked worker bundle.

## Responsibilities and Boundaries

The module owns small public verifier protocols, filesystem-backed verifier
implementations that delegate to `MojoArtifactCore`, typed verification errors,
and immutable projections containing only verified identity and deployment
metadata.

It does not own artifact authoring, mutation, staging, process launch, fd-3
transport, code loading, symbol resolution, raw handles, session lifetime,
application operations, budgets, telemetry, device selection, or hardware
acceptance. It exposes no public launcher.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`Swift Mojo`](../../DESIGN.md) | parent | Public runtime ownership boundary | Defines what downstream consumers may learn from artifact preflight. | Verification evidence is not execution evidence. |
| [`MojoArtifactCore`](../MojoArtifactCore/DESIGN.md) | depends on | Package-scoped closed-manifest verifier engines | Performs the actual tree, digest, target, and closure verification. | Internal manifests and builders are not re-exported. |
| [`MojoRuntimeProtocolCore`](../MojoRuntimeProtocolCore/DESIGN.md) | depends on | Immutable protocol schema identity | Supplies the canonical protocol metadata checked by the worker verifier. | Codec and transport are not public runtime APIs. |
| [`MojoRuntimeWorker`](../MojoRuntimeWorker/DESIGN.md) | used by | Trusted immutable worker projection | Supplies W3's only accepted artifact input and re-verifies its private copy. | This module itself retains no attempt or process state. |
| [ADR-0012](../../docs/ADR-0012-PUBLIC-RUNTIME-VERIFICATION.md) | implements | Read-only executable-bundle preflight | Defines the existing public verification boundary. | Verification-to-spawn staging belongs to W3, not this verifier. |
| [ADR-0013](../../docs/ADR-0013-CALLABLE-RUNTIME-LIBRARY-BUNDLES.md) | implements | Read-only callable-bundle preflight | Keeps executable and callable bundle types distinct. | It grants no library loading authority. |
| [ADR-0015](../../docs/ADR-0015-DIRECT-LINKED-PERSISTENT-WORKERS.md) | implements | W2 worker-bundle preflight | Adds immutable worker semantic/target/protocol identity. | It does not implement the worker transport or lifecycle. |

## Architecture

```text
consumer expected identity + staged managed root
    -> public verifier protocol
        -> MojoArtifactCore fresh closed-tree verifier
            -> immutable public verification projection
                -> consumer artifact selection or typed rejection
                -> MojoRuntimeWorker private-copy re-verification
```

## Contracts and Invariants

- Verification always re-reads the managed tree and re-derives its closed
  manifest, file digests, target, runtime closure, and loader metadata.
- Executable, callable-library, and worker bundles have distinct protocols and
  result types; a consumer cannot admit one kind as another.
- `RuntimeWorkerBundle.json` verification projects schema/protocol
  version, semantic identity, generated-input digests, target closure, relative
  executable, runtime closure, and exact binding records.
- It recomputes the pre-link `executionContractDigest`, verifies its post-link
  binding to the runtime bundle and executable, and projects the value expected
  from `ready`; it never expects the worker to self-report manifest/executable
  digests.
- Worker verification result construction is module-internal; public callers
  cannot initialize or decode an indistinguishable trusted value.
- All projected collections are immutable values in canonical order.
- A successful result means only that the inspected filesystem snapshot
  satisfied the artifact contract. It does not assert spawn, protocol preflight,
  MAX backend, device availability, session creation, kernel execution,
  performance, or safety.
- No API loads code, returns a function pointer/handle, mutates a bundle, or
  starts a process.

## Runtime Flows

```text
verify worker bundle
  -> validate managed exact tree
  -> decode closed worker/runtime/receipt manifests
  -> reproduce semantic and target-closure identities
  -> inspect executable and declared runtime libraries
  -> compare final imports, loader root, target, digests, and bindings
  -> return immutable verification or typed failure
```

## State, Ownership, and Lifecycle

Verifier instances retain only immutable configuration such as inspection tool
environment. Each call owns its local read/inspection state and returns an owned
immutable value. It retains no file descriptor, process, library, session, or
foreign handle after return.

## Failure, Concurrency, and Constraints

Malformed/unsupported schema, missing or extra files, symlinks, digest or target
drift, closure drift, unsupported inspection, and worker metadata mismatch are
typed failures. No failure becomes an empty successful result or selects a
fallback artifact. Calls share no mutable verifier state and may run
concurrently. W3 exclusively owns and protects its private staged root.

## Verification and Change Impact

Focused tests must cover successful immutable projection and every closed field,
typed missing/invalid/unsupported failures, kind confusion, unexpected tree
entries, file/manifest mutation, and absence of public construction, mutation,
loading, raw-handle, and launcher APIs. A real relocated bundle is required for
each claimed target; fixture-only tests do not prove actual target closure.

Changes require rechecking `MojoArtifactCore` manifest/verifier behavior,
`MojoRuntimeWorker`, ADR-0012/0013/0015, downstream admission compile fixtures,
and the package root design. Process lifecycle belongs to W3; hardware execution
and qualification remain separate consumer gates.
