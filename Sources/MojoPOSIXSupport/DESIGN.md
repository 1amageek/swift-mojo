# MojoPOSIXSupport

## Purpose and Scope

`MojoPOSIXSupport` is the package-scoped Swift adapter for the C portability
surface in [`CMojoPOSIXSupport`](../CMojoPOSIXSupport/DESIGN.md). Its parent
design is [`DESIGN.md`](../../DESIGN.md); it has no child components.

## Responsibilities and Boundaries

This target owns Swift string/environment marshalling, temporary C-string
storage, `Data` collection for process output, fixed-width PID/descriptor values,
platform capability checks, wait-status decoding, and typed package-internal
errors.

It does not own process timeouts, termination escalation, output-lock paths,
artifact transactions, command exit policy, or user-facing error projection.
Those decisions remain in their semantic owners.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`DESIGN.md`](../../DESIGN.md) | parent | Cross-platform authoring and consumer boundary | Defines which package paths consume this adapter. | Linux authoring remains unsupported. |
| [`CMojoPOSIXSupport`](../CMojoPOSIXSupport/DESIGN.md) | depends on | Fixed C ABI and errno output | Supplies the platform-specific operations. | Never expose borrowed C pointers beyond one call. |

## Architecture

```text
MojoCompilerCore / MojoArtifactCore / swift-mojo executable
    -> MojoPOSIXSupport typed package API
        -> owned C-string arrays and scoped buffers
            -> CMojoPOSIXSupport fixed C ABI
```

## Contracts and Invariants

- Every fallible platform operation first requires the complete supported-host
  contract; unsupported hosts throw `unsupportedPlatform`.
- Environment entries are emitted in sorted key order and live through the
  synchronous spawn call.
- Argument and environment C strings are uniquely allocated, NUL-terminated,
  and deallocated exactly once after the call.
- Output descriptors are read from offset zero until EOF; no partial read is
  treated as completion.
- `waitNoHang` distinguishes running, reaped status, outside-owner reap, and
  platform failure.
- Spawn distinguishes adapter/setup failures from an executable launch failure
  so the process owner can preserve its public error contract.
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
```

## State, Ownership, and Lifecycle

The adapter has no global mutable state. `MojoPOSIXCStringArray` owns only its
allocated strings and trailing null entry for one call. Descriptors and child
PIDs are returned to the calling owner; the adapter never closes, signals, or
reaps them implicitly.

## Failure, Concurrency, and Constraints

Errors preserve the semantic operation and platform diagnostic. Calls may run
concurrently because no adapter state is shared. The API is package-scoped so
public Mojo and artifact contracts cannot acquire platform-specific types.

## Verification and Change Impact

`MojoPOSIXSupportTests` verifies host support, exclusive locking, and status
decoding. `MojoCompilerCoreTests` verifies the real process lifecycle. The build
plugin integration test verifies that the adapter remains usable in the full
package graph on both macOS and clean Linux/aarch64. Changes require rechecking
the C design, all direct callers, and both platform paths.
