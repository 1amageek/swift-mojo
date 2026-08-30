# MojoRuntimeProtocolCore

## Purpose and Scope

`MojoRuntimeProtocolCore` is the planned package-internal SwiftPM target that
owns the direct-linked worker protocol's wire semantics. Its parent is
[`DESIGN.md`](../../DESIGN.md); it has no child components and no public library
product.

It exists so `MojoArtifactCore` worker generation and the later client
implementation share one protocol-v1 authority. It contains immutable constants,
payload schemas, validation, deterministic C rendering, and Swift codec/types,
not a runtime transport.

## Responsibilities and Boundaries

This module owns the fixed 32-byte header, closed frame-kind table, canonical
Float32 payload layouts, byte order, request pairing rules, schema digest,
payload-limit validation, and deterministic endpoint rendering.

It does not own file descriptors, reads/writes, process launch, retries,
timeouts, session/device handles, application operations, budgets, telemetry,
checkpoint policy, or hardware evidence. It is not a public product and exposes
no launcher.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`Swift Mojo`](../../DESIGN.md) | parent | Package ownership and evidence boundary | Places protocol semantics below artifact generation and above consumer transport. | Protocol compatibility is not runtime success. |
| [`MojoArtifactCore`](../MojoArtifactCore/DESIGN.md) | used by | Canonical constants, schemas, validation, and C renderer | Generates the worker C endpoint and manifest from one authority. | ArtifactCore owns files and transactions, not this module. |
| [`MojoRuntime`](../MojoRuntime/DESIGN.md) | used by | Immutable protocol schema projection | Reports the verified protocol identity to consumers. | It does not instantiate a codec or transport. |
| [ADR-0015](../../docs/ADR-0015-DIRECT-LINKED-PERSISTENT-WORKERS.md) | implements | Protocol-v1 wire contract | Defines header fields, frame kinds, lifecycle ordering, and evidence. | Any wire change requires a new protocol version. |

## Architecture

```text
ADR-0015 protocol v1
    -> immutable Swift schema + validator
        -> deterministic C worker codec/source renderer
        -> Swift codec/types for the later client implementation
        -> protocol schema digest for RuntimeWorkerBundle.json
```

## Contracts and Invariants

- The header is exactly 32 little-endian bytes:
  `UInt32 magic`, `UInt16 version`, `UInt16 kind`, `UInt64 requestID`,
  `UInt64 payloadByteCount`, and zero `UInt64 reserved`.
- The closed kinds are `ready`, `createSession`, `sessionCreated`,
  `invokeFloat32`, `invocationResult`, `shutdownSession`, `sessionShutdown`,
  `shutdownWorker`, `workerShutdown`, and `failure`.
- Request ID zero is reserved for unsolicited startup `ready` and startup
  `failure`; every consumer request is nonzero, strictly increasing, and has
  exactly one paired worker response.
- Payload length is validated against the manifest-bound positive maximum and
  the protocol-v1 implementation ceiling before allocation or decode.
- Protocol v1 admits one in-flight request. Unknown kinds, trailing bytes,
  nonzero reserved fields, invalid sequence, and malformed Float32 shape fail.
- The C renderer and Swift codec/types use the same canonical schema values and
  include their implementation versions in the protocol schema digest.
- The module contains no target/backend name in semantic payload identity.
- `executionContractDigest` covers protocol, ABI, input graph, binding, target,
  compiler, source map, digest-free generated Mojo source/object, receipt, and
  runtime-closure fields known before the C worker is rendered. It never
  includes generated C worker source/object, target-closure, executable, or
  manifest digests and is safe to embed in `ready`.

## Runtime Flows

```text
frame bytes
  -> exact 32-byte header decode
  -> magic/version/kind/reserved/request/length validation
  -> bounded payload decode for that kind
  -> typed generated endpoint value
```

Encoding performs the inverse transformation and must reproduce the canonical
bytes exactly. Stream fragmentation and transport reads/writes are handled by
the later client and generated worker owners, outside this pure codec contract.

## State, Ownership, and Lifecycle

The module has no shared mutable state and owns no runtime resource. Schema and
rendered source values are immutable. Temporary encode/decode buffers belong to
one call and cannot escape it.

## Failure, Concurrency, and Constraints

Every malformed header, kind, sequence, shape, limit, overflow, and trailing
byte condition produces a typed protocol-generation or codec failure. Integer
conversion and `elementCount * stride` are checked before indexing or
allocation. Pure codec/render operations may run concurrently.

## Verification and Change Impact

Golden C/Swift byte fixtures must cover every kind and Float32 payload, partial
stream assembly, all malformed header fields, integer/size overflow, oversize,
sequence/pairing violations, and exact schema/renderer digest invalidation.
Differential tests must feed C-rendered frames to the Swift decoder and
Swift-encoded frames to the C decoder.

Any change requires rechecking ADR-0015, `MojoArtifactCore` worker generation,
`MojoRuntime` projection, later client fixtures, Apple/NVIDIA worker
bundles, and downstream typed transport integration.
