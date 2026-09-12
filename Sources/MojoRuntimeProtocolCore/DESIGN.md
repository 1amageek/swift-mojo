# MojoRuntimeProtocolCore

## Purpose and Scope

`MojoRuntimeProtocolCore` is the package-internal SwiftPM target that
owns the direct-linked worker protocol's wire semantics. Its parent is
[`DESIGN.md`](../../DESIGN.md); it has no child components and no public library
product.

It exists so `MojoArtifactCore` worker generation and `MojoRuntimeWorker`
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
| [`Swift Mojo`](../../DESIGN.md) | parent | Package ownership and evidence boundary | Places protocol semantics below artifact generation and above W3 transport. | Protocol compatibility is not runtime success. |
| [`MojoArtifactCore`](../MojoArtifactCore/DESIGN.md) | used by | Canonical constants, schemas, validation, and C renderer | Generates the worker C endpoint and manifest from one authority. | ArtifactCore owns files and transactions, not this module. |
| [`MojoRuntime`](../MojoRuntime/DESIGN.md) | used by | Immutable protocol schema projection | Reports the verified protocol identity to consumers. | It does not instantiate a codec or transport. |
| [`MojoRuntimeWorker`](../MojoRuntimeWorker/DESIGN.md) | used by | Swift codec/types and validation | Owns W3 bounded fd-3 transport and lifecycle using this closed schema. | Raw protocol values are not re-exported publicly. |
| [ADR-0015](../../docs/ADR-0015-DIRECT-LINKED-PERSISTENT-WORKERS.md) | implements | Protocol-v1 wire contract | Defines header fields, frame kinds, lifecycle ordering, and evidence. | Wire changes update the contract digest and regenerate both endpoints. |

## Architecture

```text
ADR-0015 protocol v1
    -> immutable Swift schema + validator
        -> deterministic C worker codec/source renderer
        -> Swift codec/types for the MojoRuntimeWorker W3 implementation
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
`MojoRuntimeWorker` and the generated worker, outside this pure codec contract.
For the worker client, this module also exposes a package-level segmented
prefix decoder: it accepts the exact header and per-kind payload prefix,
returns the typed payload plus the checked Float32 body byte count, and never
materializes a complete tensor frame. The prefix widths (24 bytes for an
invocation request and 12 bytes for an invocation result) remain owned by this
module so transport code does not duplicate wire layouts.

## State, Ownership, and Lifecycle

The module has no shared mutable state and owns no runtime resource. Schema and
rendered source values are immutable. Temporary encode/decode buffers belong to
one call and cannot escape it. A segmented decode borrows only its prefix data
during parsing; the body is owned by the transport caller and is read into its
final destination after the declared count has passed checked arithmetic.

## Failure, Concurrency, and Constraints

Every malformed header, kind, sequence, shape, limit, overflow, and trailing
byte condition produces a typed protocol-generation or codec failure. Integer
conversion and `elementCount * stride` are checked before indexing or
allocation. Pure codec/render operations may run concurrently.

## Verification and Change Impact

Golden C/Swift byte fixtures must cover every kind and Float32 payload, partial
stream assembly, all malformed header fields, integer/size overflow, oversize,
sequence/pairing violations, exact schema/renderer digest invalidation, and
segmented prefix decoding with a body accepted only at the declared byte
count.
Differential tests must feed C-rendered frames to the Swift decoder and
Swift-encoded frames to the C decoder.

Any change requires rechecking ADR-0015, `MojoArtifactCore` worker generation,
`MojoRuntime` projection, `MojoRuntimeWorker` client fixtures, Apple/NVIDIA worker
bundles, and downstream typed transport integration.

## Resource Invocation Protocol (target design, 2026-09-12)

### Implemented codec boundary

MojoRuntimeResourceProtocol now owns the resource field-layout digest and widths.
MojoRuntimeBufferDescriptor validates typed readonly extents; ResourceInvocation
and ResourceResult encode/decode bounded control segments without materializing
the separate bulk body. ResourceLimits separates argument/result-value,
control, copied, mapped and result ceilings. Result capacity admission reserves
the result prefix, count table and maximum value bytes before accepting outputs.
The live frame loop, generated endpoint and public session still use Float32 invocation. These pure codecs do not enable or qualify resource worker invocation.

MojoRuntimeBufferDescriptorTests and MojoRuntimeResourceCodecTests own golden,
truncation, overflow, alias, capacity and schema gates. The independent native C
oracle in Tests/Fixtures/CMojoResourceProtocolReference differentially checks
buffer extents, invocation accounting and result rejection. macOS execution
passes 26 protocol tests with Address Sanitizer; real-worker/native Linux and
transport benchmarks remain separate gates.

This section owns the new wire semantics and replaces the Float32 worker contract directly. Resource execution remains
unqualified until the public session and generated endpoint use it. Public ownership and
failure semantics belong to [Worker](../MojoRuntimeWorker/DESIGN.md#resource-invocation-revision-2026-09-12).

Keep the 32-byte header and request-ID sequencing; both reserved fields must be zero. Retain
ready/create/session/worker shutdown messages. Replace invokeFloat32 with
invoke and its typed invocationResult. Do not retain a Float32 compatibility route or accept a
mixed closed message table.

An invocation payload contains binding ID, generated argument-schema ID,
argument-byte count, buffer count and result capacities, followed by canonical
argument bytes and buffer descriptors. Each descriptor encodes storage kind,
handle ordinal for shared storage (or payload offset for explicit copied
storage), region byte count, byte offset, element-type ID, rank, dimensions and
byte strides. All variable counts have explicit manifest-bound maxima.
Wire integers are little endian fixed-width; pointer-width/Swift Int is not wire
format. Enum IDs, widths, field ordering and reserved-zero values are generated
from the protocol-core schema in V1; the same schema produces ABI validation,
Swift/C codecs, manifest records and golden fixtures. No hand-written consumer
serialization is permitted. Shared descriptors carry zero buffer payload bytes.

The v2 canonical invocation prefix is, in order: bindingID UInt64,
argumentSchemaSHA256 32 raw bytes, argumentByteCount UInt32, inputCount UInt16,
outputCount UInt16, followed by input descriptors, output capacities, argument
bytes and any explicitly copied input bytes. An input descriptor has storageKind
UInt16 (1 copied, 2 readonly shared file, 3 Linux DMA-BUF), elementType UInt16,
rank UInt16, reserved UInt16=0, handleOrdinal UInt32 (UInt32.max for copied),
reserved UInt32=0, regionByteCount UInt64, viewByteOffset UInt64,
payloadOffset UInt64 (0 for shared), then rank pairs of dimension UInt64 and
byteStride UInt64. Element IDs 1...11 are, respectively, Int8, UInt8, Int16,
UInt16, Int32, UInt32, Int64, UInt64, Float16, Float32, Float64.
Offsets for copied buffers are relative to the copied-input area only; reject
overlap with metadata and overrun. An output capacity is elementType UInt16,
reserved UInt16=0, maximumElementCount UInt64; result shape/meaning is in the
generated binding schema, not an unvalidated caller field.

The result prefix is status Int32, outputSchemaSHA256 32 raw bytes,
valueByteCount UInt32, outputCount UInt16, reserved UInt16=0, followed by
actual output element counts UInt64 in schema order, value bytes and output
buffer bytes in that order. The admitted binding determines each output type;
all count-to-byte arithmetic is checked before receiving into final storage.
Nonzero operation status has zero value bytes/output count. Lifecycle/protocol
failures use the existing typed failure frame, never a usable result.
Generated fixed records concatenate declared-width fields without ABI padding;
fixed arrays carry their schema length, while variable counts have explicit
generated bounds. Byte ordering for copied numeric buffers is canonical little
endian. Shared buffers require matching native little-endian hosts; there is no
implicit byte swap. All enum gaps and reserved fields are rejected.

The endpoint validates all descriptors before mapping or invoking. Validate
exact field lengths, rank/type, capacity/extent arithmetic, handle count,
ordinal use, source size and access constraints through the platform importer.
Two views may reference one handle; unused or missing handles are rejected.
Every invocation result carries exact output schema, status, actual counts and
bounded output bytes. A failure response never contains usable partial output.
A valid terminal operation response also attests that input readers have
finished and invocation imports have been closed; that meaning is in the
generated ABI, not an application-provided Boolean.

### Stream and ancillary association

```text
one reserved invocation
 -> sendmsg(first control-frame bytes + ordered SCM_RIGHTS)
 -> remaining control bytes via bounded partial writes
 -> recvmsg on every receiving read, track absolute stream position
 -> validate one rights set at invocation start
 -> decode bounded invocation -> import -> invoke -> completion -> cleanup
```

Use the existing socketpair, not a second independently ordered socket.
A sender retries EINTR/EAGAIN under the same absolute deadline; after any
positive sendmsg byte count it never sends the same rights again. Receiver
uses recvmsg throughout framing so ancillary data cannot be silently discarded.
Receive the first byte of each frame with a separate one-byte recvmsg call;
only that call may carry rights. This makes the ancillary position observable
without inferring an offset inside a larger stream read. Associate it with
exactly one invocation. Ancillary data on a header/body position other than
the admitted invocation start is a terminal protocol failure. The sender cannot
pipeline another invocation. Read syscall sizes respect the current frame boundary.

MSG_CTRUNC, multiple rights sets, unexpected control types, wrong descriptor
count, invalid mapping, premature EOF or trailing bytes close every descriptor
already received and terminate the attempt. CLOEXEC is set atomically where
supported, otherwise before exposing the received handle; the child does not
spawn while an unsealed received descriptor exists. The no-fork/import
critical region belongs to the platform endpoint.

Inline value/result bytes are bounded ordinary IPC; bulk shared input is not
counted as wire payload but is checked against a separate mapped-byte ceiling.
The protocol digest covers value schema, buffer descriptors, handle semantics,
completion semantics and all maxima. Ready proves the new digest before any
shared buffer can be sent.

### Verification impact

Differential C/Swift tests cover ordinary and zero-length inputs, strided views,
all scalar encodings and every arithmetic boundary. Native socketpair tests
cover one-byte fragmentation, EAGAIN after partial sendmsg, truncation,
unrelated descriptors, EOF at every boundary and cancellation at transfer.
Descriptor counts before/after each failing exchange must match.
Recheck [ArtifactCore](../MojoArtifactCore/DESIGN.md),
[Runtime](../MojoRuntime/DESIGN.md), Worker and
[POSIXSupport](../MojoPOSIXSupport/DESIGN.md) together.
