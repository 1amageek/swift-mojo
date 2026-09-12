# CMojoPOSIXSupport

## Shared-input native primitives (target design, 2026-09-12)

The ancillary and readonly file primitives are now implemented in
`CMojoPOSIXRights.c` and `CMojoPOSIXSharedInput.c`; public resource admission and
worker protocol selection remain separate pending work. Sockets must already
be nonblocking (checked before I/O); Darwin's `MSG_DONTWAIT` alone did not bound
a large `sendmsg` in the native test. The existing worker socket factory sets
both nonblocking and Darwin no-SIGPIPE options.

Darwin's receive buffer always accommodates 512 descriptors, independently of
the invocation limit. XNU's `UIPC_MAX_CMSG_FD` bounds kernel rights conversion;
`unp_externalize` installs descriptors before `recvmsg` truncates user control
storage. Receiving only the admitted capacity leaked undisclosed descriptors
in the native regression. The implementation receives the kernel-bounded set,
then closes every excess descriptor. Linux retains its kernel truncation
behavior. Reference: [XNU Unix socket implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/uipc_usrreq.c).

Readonly duplication checks access and accessible extent. DMA-BUF identity is
qualified with START/END before its size-discovery seeks; a mislabeled regular
file fails without changing the producer's shared file offset. START/END preserve EINTR/EAGAIN for the
owner's bounded retry; the native primitive never retries without a deadline.
[Kernel DMA-BUF contract](https://docs.kernel.org/driver-api/dma-buf.html)
requires cache-coherency bracketing and separate producer-completion ownership.

`MojoPOSIXRightsTests` and `MojoPOSIXSharedInputTests` exercise real socketpairs,
partial send, first-byte rights association, occupied-slot rejection, bounded
excess cleanup, backing identity, readonly mapping and invalid native inputs.
They do not yet prove a real DMA-BUF successful read or worker terminal lifetime.

Qualification on 2026-09-12: Mac Swift 6.4.2-dev `d2e983b81b18217` passed
all 21 POSIX tests under ASan and three guarded repetitions of the six new
tests. Jetson Linux/aarch64 Swift 6.4-dev `424cae54c1a10da` passed the same six
new tests against original C/Swift sources, using LLD with
`-z nostart-stop-gc`. Linux ASan was not qualified: its C aggregate object failed
to link because relocations referenced discarded sections. Native logs are
`.build/native-resource-proof/linux.log`; Mac logs are
`/tmp/swift-mojo-posix-final.log` and `/tmp/swift-mojo-native-hang-guard.log`.

Implement the fixed-width C operations required by
[WorkerPOSIX](../MojoRuntimeWorkerPOSIX/DESIGN.md) and
[POSIXSupport](../MojoPOSIXSupport/DESIGN.md#shared-input-adapter-delta-target-design-2026-09-12):
readonly descriptor duplication/admission, bounded SCM_RIGHTS send/receive,
readonly region mapping and Linux DMA-BUF read synchronization. Keep errno
and partial progress explicit; consume descriptor slots before close attempts.
The existing C ABI remains private. No camera format, GPU runtime or model
selection belongs here. Unsupported Darwin/Linux storage kinds fail explicitly.
Tests prove no descriptor leaks for truncated ancillary data, multiple rights
sets, failed map/sync and interrupted/partial transfer; actual platform behavior
is required, not only generated declarations.


## Purpose and Scope

`CMojoPOSIXSupport` is the internal C target that normalizes the small POSIX ABI
surface required by `swift-mojo`. Its parent design is
[`DESIGN.md`](../../DESIGN.md); it has no child components.

The supported implementations are Darwin and glibc 2.34 or newer. Other hosts,
including older glibc releases that lack `posix_spawn_file_actions_addclosefrom_np`,
must still compile this target and report an unsupported platform at runtime.

## Responsibilities and Boundaries

This target owns the C representation of file descriptors, advisory locks,
`socketpair`, `posix_spawn`, descriptor mapping, bounded poll/read/write,
non-reaping exact-child observation, bounded process-group enumeration,
process-group signaling, `waitpid`, regular-input opening, `fstat`, seek/read,
error text, and process exit. It normalizes platform declarations and constants
into fixed-width C values.

It does not own timeout policy, polling intervals, command construction,
temporary paths, output decoding, artifact identity, or Swift error types. It
does not retry `close`, because a failed `close` may already have released and
reused the descriptor.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`DESIGN.md`](../../DESIGN.md) | parent | Cross-platform authoring and consumer boundary | Defines the package-level portability and evidence boundary. | Device and product policy remain downstream. |
| [`MojoPOSIXSupport`](../MojoPOSIXSupport/DESIGN.md) | used by | Fixed C functions and error codes | Converts this ABI into package-scoped Swift operations. | C pointers never escape the synchronous call. |
| [`MojoRuntimeWorker`](../MojoRuntimeWorker/DESIGN.md) | used by | W3 socket/spawn/I/O/signal/wait primitives through the Swift adapter | Keeps raw platform state below the public worker client. | PIDs, descriptors, and pointers never cross W3's public boundary. |
| [ADR-0015](../../docs/ADR-0015-DIRECT-LINKED-PERSISTENT-WORKERS.md) | coordinates with | Process/descriptor ownership boundary | Reserves fd 3 for W3's persistent-worker transport. | The compiler-tool and worker spawn ABIs remain distinct. |

## Architecture

```text
Swift package-scoped adapter
    -> target-internal Swift C-linkage declarations
        -> private fixed-width C ABI
        -> Darwin socket/spawn/fd-map, poll/I/O, flock, wait, signal, file operations
        -> glibc 2.34+ socket/spawn/fd-map, poll/I/O, closefrom, flock, wait, signal, file operations
        -> unsupported implementation returning ENOTSUP
```

## Contracts and Invariants

- Regular input admission uses `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`
  and checks the opened descriptor with `fstat`, returning its byte count.
  Failed admission closes the descriptor; successful admission transfers it
  to the Swift caller. No source pointer escapes the synchronous call.

- `swift_mojo_posix_platform_supported()` returns one only when the complete
  process and descriptor contract is available.
- A successful spawn returns one child PID in a new session/process group,
  redirects stdout and stderr to the supplied descriptor, and prevents other
  descriptors from leaking into the child.
- The existing tool-process spawn ABI deliberately preserves no protocol
  descriptor and continues to close fd 3.
- A distinct W3 worker-spawn ABI creates or accepts one socketpair, maps only the
  child endpoint to descriptor 3, closes both unused endpoint copies in each
  process, preserves diagnostic output separately, and closes other inherited
  descriptors. It cannot execute an arbitrary path not supplied by W3's trusted
  private-stage contract.
- Worker read/write/poll operations report partial progress, EOF, timeout, and
  interruption distinctly. They do not allocate from an untrusted frame length
  or interpret protocol bytes.
- Spawn returns distinct setup/control and executable-launch failure sentinels;
  the errno-compatible diagnostic remains in the error output.
- Spawn setup objects do not own the child. Destroying those objects cannot turn
  a successful spawn into a failure that discards the child PID.
- Lock, read, and wait operations retry only when interrupted before completion.
- `close` is attempted exactly once.
- `wait_nohang` reaps exactly the supplied child PID and returns its opaque POSIX
  wait status without interpreting it.
- Exact-child observation uses `waitid` with `WEXITED | WNOHANG | WNOWAIT`,
  preserves the waitable child, and reports running, normal exit, signal exit,
  or an errno-compatible failure without projecting `ECHILD` as termination.
- Signaling targets the whole process group; an already absent group is success.
- Process-group inspection returns alive, gone, or indeterminate and examines no
  more than a fixed number of process records. Linux `/proc` and Darwin process
  enumeration both stop at that ceiling; enumeration failure or ceiling
  exhaustion is indeterminate rather than gone.
- Group membership inspection excludes zombies from live members while the
  direct-child observation continues to preserve the waitable PID identity.
- The public Clang header is intentionally declaration-free. Raw declarations
  live only in the target-private header and are consumed through target-internal
  Swift C-linkage declarations.
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

termination observation
  -> waitid(exact child, WEXITED | WNOHANG | WNOWAIT)
  -> running, normal exit, signal exit, or errno
  -> bounded group-member enumeration
  -> alive, gone, or indeterminate

worker spawn request
  -> create socketpair and initialize worker-only file actions/attributes
  -> map child endpoint to fd 3 and close unused descriptors
  -> create new session/process group and publish parent endpoint + PID
  -> destroy setup objects

worker I/O request
  -> bounded readiness wait
  -> partial read/write, EOF, timeout, or errno result

regular input request
  -> open with no-follow, nonblocking, and close-on-exec flags
  -> fstat the opened descriptor and require a regular file
  -> return owned descriptor + exact size, or errno-compatible failure
```

## State, Ownership, and Lifecycle

The Swift adapter/W3 caller owns every descriptor and PID. This target neither stores them nor
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

`MojoPOSIXSupportTests` exercises lock exclusion, regular-input link/type/size
admission, and wait-status compatibility.
`MojoCompilerCoreTests` exercises real spawn success, nonzero exit, timeout,
descendant termination, and reap behavior on Darwin and Linux. Changes to this
ABI require rechecking `MojoPOSIXSupport`, `MojoCompilerCore`, output locking,
the command executable, and the clean Linux/aarch64 consumer fixture.
The distinct worker descriptor-map ABI requires ADR-0015 W3 lifecycle tests for
fd 3, unused-descriptor closure, partial I/O, timeout, process-group termination,
and reap. It must not silently change current compiler child inheritance.
