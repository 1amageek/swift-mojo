# MojoRuntimeWorkerPOSIX

## Purpose and Scope

Implemented native input adapter. Parent: [package](../../DESIGN.md).
No child components. One new SwiftPM target/product isolates public native
resource admission from the portable worker API. It introduces no process host.
This is the narrow exception to the earlier package-wide ban on public native
descriptor inputs; the portable products still expose none.

## Responsibilities and Boundaries

Import a borrowed read-only POSIX shared-storage descriptor plus a strong
producer read-lease owner and validated allocation extent. Duplicate it with
CLOEXEC, retain the producer, and return a portable MojoReadOnlyBuffer through
a package-only constructor. Ordinary consumers receive an owned safe value;
only a platform integration adapter handles raw descriptor admission.

The public factory is
MojoPOSIXSharedInput.importReadOnly(descriptor:byteCount:retaining:kind:).
The retaining argument is a Sendable reference whose lifetime guarantees
content stability and fixed allocation size. Retaining an arbitrary object
without that producer guarantee violates the import precondition. Source owner
operations remain camera/file/audio-driver contracts, not bridge protocols.

The admitted buffer retains an immutable native storage owner. Foundation
`FileHandle(fileDescriptor:closeOnDealloc:true)` owns its sole duplicate; this
private handle is never exposed or mutated. Its documented final-release
descriptor policy supplies RAII, without a new finalizer registry. Construction
failure uses explicit throwing close and preserves cleanup errors. Attempt and
receiver descriptor cleanup remain explicit, fallible worker operations.
Native buffers do not expose a producer-side map API; worker invocation owns
map/sync and joins readers before terminal acknowledgement. Host sources use
the separate portable host-borrow initializer.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Worker](../MojoRuntimeWorker/DESIGN.md#resource-invocation-revision-2026-09-12) | depends on | Portable immutable buffer, package constructor | Returns admitted source | No native handle in portable API |
| [POSIXSupport](../MojoPOSIXSupport/DESIGN.md) | depends on | Duplicate/map/readonly synchronization | Uses existing C platform machinery | Same descriptor/errno ownership |
| [ProtocolCore](../MojoRuntimeProtocolCore/DESIGN.md) | coordinates with | Storage-kind and ancillary schema | Encodes platform capability | No domain-format IDs |

## Architecture

```text
platform producer adapter -> MojoRuntimeWorkerPOSIX
                           -> MojoRuntimeWorker portable input
                           -> MojoPOSIXSupport -> CMojoPOSIXSupport
worker generated endpoint -> platform import helpers -> scoped readonly view
```

Worker does not depend on WorkerPOSIX. WorkerPOSIX depends on Worker and
POSIXSupport; there is no cycle. This new target is justified by public
platform-specific visibility, not by a new abstraction hierarchy.

## Contracts and Invariants

Initial storage capabilities: immutable-sized readonly regular shared memory
on supported Darwin/glibc hosts, and Linux DMA-BUF. Admission distinguishes
them explicitly; a descriptor kind string is not evidence of kernel support.
Validate read access mode, allocation extent, view extent, CLOEXEC and
applicable synchronization capability before dispatch. Reject unsupported
storage/host combinations and failed duplication explicitly.

The bridge neither requeues nor returns source storage to its producer.
An imported descriptor belongs to the bridge exactly once; the source fd remains
borrowed and is never closed by it. Closing a duplicated fd does not end the
producer read lease. Close consumes the slot before calling the OS and is never
retried by integer value after failure. Size cannot change during the lease;
readonly descriptor permissions alone do not prevent another owner truncating.

DMA-BUF CPU access brackets each imported read with required DMA_BUF_IOCTL_SYNC
START/END READ operations and maps PROT_READ only. These calls and their failures
belong to this platform adapter/generated endpoint, not user Mojo kernels.
The native driver must have completed producing the frame before leasing it.
A GPU transfer that reads host mapped memory is joined before END/unmap.
No CUDA external-memory import, GPU address identity or cache-coherence guarantee
is inferred from successful mmap. Future GPU imports need their own qualified
capability; no public API claims them now.

## Runtime Flows

Import retains producer -> duplicate/admit -> worker rights transfer ->
validate received resource -> synchronize/map -> invoke with readonly borrow ->
join readers -> end access/unmap/close -> terminal response -> source release.

## State, Ownership, and Lifecycle

The input owner holds a duplicate and producer lease. Worker mappings are
invocation-owned. Scalar metadata is immutable; short shared lifecycle state is
protected by Mutex on every supported host. No I/O/callback occurs under that
mutex. Unconfirmed cleanup follows Worker retention, including facade destruction.

## Failure, Concurrency, and Constraints

Typed failures cover unsupported kind/host, invalid descriptor/access/extent,
overflow/alignment, duplicate failure, synchronization, mapping and close failure.
Retain the source while cleanup is uncertain. Adapter failure does not create
a host copy. Caller-owned copied input is a separate explicit route.

## Verification and Change Impact

`Tests/MojoRuntimeWorkerPOSIXTests/MojoPOSIXSharedInputTests.swift` proves public
producer retention, duplicate release, source descriptor preservation, explicit
host storage without eager materialization, and admission failure. Mislabeled
regular-file DMA input must preserve its shared file offset and leak no duplicate.
Mac uses the complete package graph with ASan. Native Linux uses the same input
source files in an isolated focused package with the installed Swift toolchain;
this is not full worker/package acceptance.

The [native fixture](../../Acceptance/RuntimeWorker/Fixtures/NativeInput/NativeInputConsumer.swift)
imports a real Jetson V4L2 readonly DMA-BUF after SCM_RIGHTS transfer, verifies a
shared marker through READ START/END and readonly mapping, unmaps, then proves
producer release. The producer retains the source allocation until child exit.
This qualifies native input ownership and platform primitives, not worker v2,
GPU device reads, latency or RT4 receipt acceptance.

Verified on 2026-09-12: Mac ASan3 ownership tests plus21 POSIX regressions;
Jetson/aarch64 focused3 ownership plus6 native primitive tests; actual4147200-byte
V4L2 DMA-BUF shared marker and producer release. Linux uses Swift424cae54c1a10da
and LLD metadata retention. Evidence: `.build/native-resource-proof/linux-public.log`,
device `/data/lume-max-camera-build/swift-mojo-native-proof/dma-public.log`,
and `/tmp/swift-mojo-public-input-final.log`. The camera service was restored
through its original systemd-run/unshare command, and live Mac telemetry plus
advancing Jetson Pose/Video logs were observed afterward. A transient unit can
disappear after stop: preserve its launch command rather than relying on start.

Native tests must use real shared allocations on Darwin and glibc, and real
DMA-BUF on a capable Linux host. Prove identical backing bytes, readonly
mapping/write rejection, producer retention, malformed descriptor rejection,
synchronization failure and leak-free partial transfer. Non-camera immutable
shared-memory numeric data must pass the same public worker path.
Compile does not prove native synchronization. Unavailable DMA-BUF hardware
remains unqualified rather than silently using a different resource.
Changes recheck Worker, ProtocolCore, both POSIX targets and producer adapters.
