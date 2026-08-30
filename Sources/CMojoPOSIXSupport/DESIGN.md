# CMojoPOSIXSupport

## Purpose and Scope

`CMojoPOSIXSupport` is the internal C target that normalizes the small POSIX ABI
surface required by `swift-mojo`. Its parent design is
[`DESIGN.md`](../../DESIGN.md); it has no child components.

The supported implementations are Darwin and glibc 2.34 or newer. Other hosts,
including older glibc releases that lack `posix_spawn_file_actions_addclosefrom_np`,
must still compile this target and report an unsupported platform at runtime.

## Responsibilities and Boundaries

This target owns the C representation of file descriptors, advisory locks,
`posix_spawn`, process-group signaling, `waitpid`, seek/read, error text, and
process exit. It normalizes platform declarations and constants into fixed-width
C values.

It does not own timeout policy, polling intervals, command construction,
temporary paths, output decoding, artifact identity, or Swift error types. It
does not retry `close`, because a failed `close` may already have released and
reused the descriptor.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`DESIGN.md`](../../DESIGN.md) | parent | Cross-platform authoring and consumer boundary | Defines the package-level portability and evidence boundary. | Device and product policy remain downstream. |
| [`MojoPOSIXSupport`](../MojoPOSIXSupport/DESIGN.md) | used by | Fixed C functions and error codes | Converts this ABI into package-scoped Swift operations. | C pointers never escape the synchronous call. |

## Architecture

```text
Swift package-scoped adapter
    -> fixed-width C ABI
        -> Darwin spawn, flock, wait, signal, file operations
        -> glibc 2.34+ spawn, closefrom, flock, wait, signal, file operations
        -> unsupported implementation returning ENOTSUP
```

## Contracts and Invariants

- `swift_mojo_posix_platform_supported()` returns one only when the complete
  process and descriptor contract is available.
- A successful spawn returns one child PID in a new session/process group,
  redirects stdout and stderr to the supplied descriptor, and prevents other
  descriptors from leaking into the child.
- Spawn returns distinct setup/control and executable-launch failure sentinels;
  the errno-compatible diagnostic remains in the error output.
- Spawn setup objects do not own the child. Destroying those objects cannot turn
  a successful spawn into a failure that discards the child PID.
- Lock, read, and wait operations retry only when interrupted before completion.
- `close` is attempted exactly once.
- `wait_nohang` reaps exactly the supplied child PID and returns its opaque POSIX
  wait status without interpreting it.
- Signaling targets the whole process group; an already absent group is success.
- Linux liveness checks use `/proc` to distinguish live processes from zombies;
  zombies are already terminated and do not keep cleanup waiting indefinitely.
- Unsupported implementations return `ENOTSUP` and never report a successful
  no-op.

## Runtime Flows

```text
spawn request
  -> initialize file actions and attributes
  -> duplicate output descriptor
  -> close inherited descriptors
  -> require new-session spawn flag
  -> spawn and publish PID
  -> destroy setup objects

wait request
  -> waitpid(child, WNOHANG)
  -> running, reaped status, or errno
```

## State, Ownership, and Lifecycle

The caller owns every descriptor and PID. This target neither stores them nor
creates background work. Spawn action and attribute objects are local values and
are destroyed before return. Buffers, strings, pointer arrays, and error outputs
are borrowed only for one synchronous C call.

## Failure, Concurrency, and Constraints

All functions are thread-safe to the extent of their underlying POSIX operation
and hold no shared mutable state. Failure is represented by a sentinel return and
an errno-compatible output. `posix_spawn_file_actions_addclosefrom_np` is a hard
glibc 2.34 boundary; older glibc builds select the unsupported path rather than
referencing an unavailable symbol.

## Verification and Change Impact

`MojoPOSIXSupportTests` exercises lock exclusion and wait-status compatibility.
`MojoCompilerCoreTests` exercises real spawn success, nonzero exit, timeout,
descendant termination, and reap behavior on Darwin and Linux. Changes to this
ABI require rechecking `MojoPOSIXSupport`, `MojoCompilerCore`, output locking,
the command executable, and the clean Linux/aarch64 consumer fixture.
