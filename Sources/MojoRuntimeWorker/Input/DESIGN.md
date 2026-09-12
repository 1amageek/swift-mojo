# Worker Input Ownership

## Purpose and Scope

Own immutable input storage retained across invocation. Parent:
[MojoRuntimeWorker](../DESIGN.md). No children. This component does not implement
worker invocation or qualify its completion.

## Responsibilities and Boundaries

Host sources provide scoped initialized bytes, stable size and immutable contents.
Native importers grant sharing eligibility and retain the real producer lease.
MojoBufferView owns an immutable typed layout over that admitted buffer.
This component stores those owners without mapping, copying, hashing, scheduling,
model knowledge or direct platform admission.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Worker](../DESIGN.md) | parent | Invocation reader lifetime | Retains inputs through terminal proof | Local I/O completion is insufficient |
| [WorkerPOSIX](../../MojoRuntimeWorkerPOSIX/DESIGN.md) | used by | Package shared constructor | Supplies owned native ingress | Public conformers cannot grant sharing |
| [ProtocolCore](../../MojoRuntimeProtocolCore/DESIGN.md) | depends on | Storage kind | Separates copied/shared routes | Binding-specific extent validation belongs at invocation |

## Architecture

```text
host producer -> MojoBufferSource -> MojoReadOnlyBuffer -> attempt retention
native producer -> WorkerPOSIX -> retained descriptor/producer owner --^
```

## Contracts and Invariants

`MojoBufferSource` is the host-borrow protocol: immutable `byteCount` and scoped
readonly bytes, with storage stability for the retained source lifetime.
`MojoReadOnlyBuffer(hostSource:)` retains it for explicit copied transport.
The admitted buffer itself is an opaque immutable owner, not a new host mapping
API. A native import stores its descriptor and producer lease without forcing
CPU mapping in the producer process. Native mappings belong to the worker
invocation; this avoids duplicating map/sync lifecycle in both public products.
The package-only shared constructor cannot be invoked by external conformers.

`MojoBufferElementType` projects supported numeric types without exposing wire
identifiers. `MojoBufferView` retains the buffer and its offset/dimensions/byte
strides, using ProtocolCore's checked extent validator against the actual owner
size. Construction permits empty layouts; binding admission must independently
apply its verified empty/rank/type/size restrictions. Layout errors are exposed as
`MojoInputBufferError.invalidLayout` with the original diagnostic. No borrow, mapping,
copy, normalization or repacking occurs at view construction.

The native importer owns one duplicate for the admitted buffer lifetime.
Transport borrows that descriptor for sendmsg; it does not create a redundant
sender duplicate per invocation. Kernel-created receiver descriptors remain
invocation-owned and their close errors are part of terminal processing.

## State, Ownership, and Lifecycle

The buffer stores immutable byteCount and storage fields, and is Sendable without
unchecked conformance. The external source contract guarantees content stability.
A host source is retained without invoking its byte callback at construction.
A native owner holds its descriptor and producer; the component never closes a
borrowed native descriptor. Final release follows all attempt-owned reader leases.

## Failure, Concurrency, and Constraints

Negative host size and nonpositive native size are rejected before admission.
Host byte pointers cannot escape the callback. Metadata/source consistency and
binding capacities are revalidated by the invocation owner before dispatch.
Concurrent readers require immutable storage; input constructors create no task,
queue or mutable shared state. No hidden copied fallback is provided.

## Verification and Change Impact

[Public input tests](../../../Tests/MojoRuntimeWorkerPOSIXTests/MojoPOSIXSharedInputTests.swift)
prove retained host/native owners, no eager host borrow, release of only the owned
duplicate, negative/empty size behavior and explicit native admission failure.
Worker lifecycle tests must separately prove retention through asynchronous
completion and unconfirmed teardown before v2 invocation promotion. Changes affect
the parent worker and native importer; camera/model policy remains downstream.
