# MojoPOSIXSupport

## Shared-input adapter delta (target design, 2026-09-12)

Implemented lower boundary: `MojoPOSIXRightsSupport` reports partial byte progress
and transferred descriptor count using caller-preallocated empty slots; failures
consume all received slots and preserve primary/cleanup errno separately.
`MojoPOSIXSharedInputSupport` supplies readonly duplication, scoped-owner mapping
primitives and explicit DMA-BUF synchronization outcomes. These primitives do not
grant public sharing eligibility or retain a producer themselves; WorkerPOSIX
still must compose admission and ownership before this path can serve callers.

[WorkerPOSIX](../MojoRuntimeWorkerPOSIX/DESIGN.md) is a new public native ingress
consumer of this existing package-only adapter. This target stays private.
Add typed duplicate/read-access/extent/import/synchronization operations and
bounded sendmsg/recvmsg ancillary results. CMojoPOSIXSupport owns OS calls;
ProtocolCore owns rights/frame association; Worker owns deadline and lifetime.
Never marshal pixel/sample storage through Data. Return owned descriptor
collections with consuming close on every malformed/partial path.
Native Darwin/glibc ancillary tests and Linux DMA-BUF tests qualify these
changes separately from existing regular-file staging/spawn tests.


## Purpose and Scope

`MojoPOSIXSupport` is the package-scoped Swift adapter for the C portability
surface in [`CMojoPOSIXSupport`](../CMojoPOSIXSupport/DESIGN.md). Its parent
design is [`DESIGN.md`](../../DESIGN.md); it has no child components.

## Responsibilities and Boundaries

This target owns Swift string/environment marshalling, temporary C-string
storage, `Data` collection for process output, fixed-width PID/descriptor values,
socket-endpoint marshalling, bounded partial-I/O results, platform capability
checks, regular-input descriptor admission, non-reaping child observation,
bounded process-group inspection, wait-status decoding, and typed
package-internal errors.

It does not own process timeouts, cancellation policy, termination escalation,
output-lock paths, artifact transactions, command exit policy, or user-facing
error projection. Those decisions remain in their semantic owners. It exposes
no public product or filesystem, PID, descriptor, or raw-frame contract.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`DESIGN.md`](../../DESIGN.md) | parent | Cross-platform authoring and consumer boundary | Defines which package paths consume this adapter. | Linux authoring remains unsupported. |
| [`CMojoPOSIXSupport`](../CMojoPOSIXSupport/DESIGN.md) | depends on | Fixed C ABI and errno output | Supplies the platform-specific operations. | Never expose borrowed C pointers beyond one call. |
| [`MojoRuntimeWorker`](../MojoRuntimeWorker/DESIGN.md) | used by | Package-scoped worker spawn and bounded I/O | Owns the public generic worker client and consumes this target only as an internal platform adapter. | Worker attempt policy and lifecycle stay in `MojoRuntimeWorker`. |
| [ADR-0015](../../docs/ADR-0015-DIRECT-LINKED-PERSISTENT-WORKERS.md) | coordinates with | Attempt-owned fd-3 boundary | Separates the worker transport from authoring-tool processes. | The existing tool-spawn ABI and the worker-spawn ABI remain distinct. |

## Architecture

```text
MojoCompilerCore / MojoArtifactCore / swift-mojo executable / MojoRuntimeWorker
    -> MojoPOSIXSupport typed package API
        -> owned C-string arrays and scoped buffers
            -> target-internal @_extern(c) declarations
                -> CMojoPOSIXSupport private fixed C ABI
```

## Contracts and Invariants

- `openRegularInputFile` returns one caller-owned read-only descriptor and its
  `fstat` byte count. It rejects a final symbolic link and non-regular file,
  opens nonblocking to avoid a FIFO admission hang, and sets close-on-exec.
  W3 owns content identity, copying, deadline checks, and explicit close.

- Every fallible platform operation first requires the complete supported-host
  contract; unsupported hosts throw `unsupportedPlatform`.
- Environment entries are emitted in sorted key order and live through the
  synchronous spawn call.
- Argument and environment C strings are uniquely allocated, NUL-terminated,
  and deallocated exactly once after the call.
- Output descriptors are read from offset zero until EOF; no partial read is
  treated as completion.
- `observeChild` uses a non-reaping exact-child wait and distinguishes running,
  normal exit, signal exit, outside-owner reap, and inspection failure.
- `waitNoHang` remains the only exact-child reap operation and distinguishes
  running, reaped status, outside-owner reap, and platform failure.
- Process-group inspection returns `alive`, `gone`, or `indeterminate` within a
  fixed platform work ceiling. `indeterminate` is never projected as absence;
  the compatibility Boolean treats it as alive.
- Group signaling is a separate primitive. Its caller must first establish
  exact-child ownership with `observeChild` and must never signal after reap.
- Spawn distinguishes adapter/setup failures from an executable launch failure
  so the process owner can preserve its public error contract.
- Current spawn is only the compiler/linker/inspector tool-process contract. It
  does not create a socketpair or map a child protocol endpoint to fd 3 and must
  not be presented as ADR-0015 worker launch support.
- The distinct package-internal worker-spawn operation creates one socketpair,
  maps only the child endpoint to fd 3, closes unused inherited endpoints, and
  returns the parent endpoint plus owned child PID to `MojoRuntimeWorker`.
- Worker reads, writes, and readiness waits report bounded progress, EOF,
  interruption, timeout, and platform failure without treating a partial frame
  as completion. The worker wakeup endpoint is drained through a bounded
  package operation after poll reports readability; coalesced cancellation
  tokens are never interpreted as protocol bytes.
- Worker spawn clears the inherited signal mask and restores TERM, INT, HUP,
  and PIPE to their default dispositions before `exec`. The worker may install
  its own handlers after startup, but a blocked or ignored signal state from
  the calling Swift executor cannot disable lifecycle escalation.
- Exit status decoding maps normal exit to its exact code and signal termination
  to `128 + signal`.
- The adapter does not silently substitute Foundation `Process`, a no-op lock,
  or a different digest/process implementation.

## Runtime Flows

```text
Swift spawn
  -> validate supported host
  -> allocate argv and optional sorted envp
  -> call C spawn synchronously
  -> release argv/envp storage
  -> return owned PID or typed error

Swift output read
  -> seek descriptor to zero
  -> append bounded chunks until EOF
  -> return owned Data

Swift regular input admission
  -> open without following links and with nonblocking/close-on-exec flags
  -> require regular-file metadata and obtain exact size from the descriptor
  -> return the owned descriptor or a typed package-internal error

Swift worker spawn
  -> receive a verified private-stage executable from MojoRuntimeWorker
  -> create socketpair and map the child endpoint to fd 3
  -> close unused endpoints in each process
  -> return the parent endpoint and owned PID

Swift worker I/O
  -> poll for readiness within the caller-provided bound
  -> read or write a bounded byte region
  -> report exact progress or typed terminal status

Swift worker termination inspection
  -> observe exact child without reaping
  -> inspect process group with a fixed work ceiling
  -> return typed child and tri-state group observations
  -> caller completes every signal before exact-child reap

Swift cancellation wakeup
  -> set cancellation state under the caller-owned Mutex
  -> best-effort write one coalesced wakeup token
  -> poll returns wakeup readiness
  -> bounded drain clears tokens before the attempt classifies cancellation
```

## State, Ownership, and Lifecycle

The adapter has no global mutable state. `MojoPOSIXCStringArray` owns only its
allocated strings and trailing null entry for one call. Descriptors and child
PIDs are returned to the calling owner. For worker attempts that owner is
`MojoRuntimeWorker`, which closes, signals, and reaps them through explicit
package-scoped operations; the adapter performs no implicit lifecycle action.

## Failure, Concurrency, and Constraints

Errors preserve the semantic operation and platform diagnostic. Calls may run
concurrently because no adapter state is shared. The API is package-scoped so
public Mojo and artifact contracts cannot acquire platform-specific types. The
public Clang header contains no declarations; only the private C header and the
target-internal Swift C-linkage declarations can name the raw ABI.

## Verification and Change Impact

`MojoPOSIXSupportTests` verifies host support, exclusive locking, typed
regular-input link/type/size admission, non-reaping child observation, bounded
tri-state group inspection, status decoding, worker descriptor mapping, partial
I/O, EOF, interruption, and timeout results.
`MojoCompilerCoreTests` verifies the existing tool-process lifecycle.
`MojoRuntimeWorker` acceptance verifies the distinct worker lifecycle on macOS
and native Linux/aarch64. The build-plugin integration test verifies that the
adapter remains usable in the full package graph on both hosts. Changes require
rechecking the C design, all direct callers, and both platform paths.
`MojoRuntimeWorker` owns fd-3 full-duplex I/O policy, deadlines, cancellation,
and attempt lifecycle; `MojoRuntime` remains a read-only verifier.
