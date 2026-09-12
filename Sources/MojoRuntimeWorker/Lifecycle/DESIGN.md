# Worker Lifetime

## Purpose and Scope

Parent: [Worker](../DESIGN.md). No children. Own the single-attempt admission
reservation shared by all copies of a worker and the independent retention
obligation after uncertain process cleanup.

## Responsibilities and Boundaries

The terminalizer owns process observation and signals. This component owns the
reservation, immutable input owners and bounded recovery scheduling. It does not
interpret buffers, perform transport or infer device completion.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Worker](../DESIGN.md) | parent | Exact-child terminal proof | Receives cleanup facts | Local I/O completion cannot release readers |
| [Input](../Input/DESIGN.md) | depends on | Immutable producer retention | Holds input owners through uncertainty | No pixel copy or eager borrow |

## Architecture

```text
worker copies -> one Mutex reservation -> one attempt
                                      -> uncertain cleanup -> detached recovery
                                          retains inputs -> exact termination proof
                                                         -> release inputs
```

## Contracts and Invariants

A reservation precedes staging/spawn. Concurrent admission fails before I/O.
Normal completion releases it. Unconfirmed cleanup permanently closes admission
on this worker owner and transfers its source owners to a detached task before
returning the cleanup error. No caller reference, cancellation or timeout can
release those owners. Status reports retained bytes and recovery failures.
The task has no input queue and creates no new process or buffer.

## State, Ownership, and Lifecycle

All state uses one Mutex on supported native macOS/Linux; this POSIX worker is
not a WASM/Embedded target. Admission, finish, quarantine and recovery completion
use the same lock. Task creation, process I/O and owner destruction occur outside
it. Each recovery episode revalidates the unreaped child identity and uses the
existing termination/forced-cleanup durations. Between episodes it suspends for
the supplied forced-cleanup duration. Failed observations never authorize reuse.
After proven process death, stage cleanup is attempted and its failure remains
observable; inputs may be released even if stage removal fails.

## Failure, Concurrency, and Constraints

Only the unique terminal cleanup claim may transfer a retention obligation.
Each episode is bounded; the total obligation is intentionally not time bounded.
External reaping remains fail closed and cannot cause signals to a reused PGID.
The worker stays closed after recovery; a new worker is an explicit caller action.

## Verification and Change Impact

Lifecycle tests must prove concurrent admission, zero eager input borrow,
retention after every caller reference is dropped, delayed termination proof,
exactly-once release and failure status. Existing Worker tests cover startup,
cancellation and shutdown callers. Resource invocation tests must additionally
prove the submitted owners reach this component on every failed exchange.

Mac verification for this implementation: all 69 Worker tests passed, including
public worker value-copy admission. Five focused tests passed under Thread
Sanitizer with no race report; the sanitizer emitted an invalid dyld module map
warning, so its backtrace reliability is limited. Linux recovery qualification
and resource-invocation integration remain separate required acceptance gates.

| State owner | macOS/Linux storage | Read/mutation | Release | WASM/Embedded |
|---|---|---|---|---|
| Lifetime | Mutex<State> | status/begin/finish/quarantine/recovery | Detached reader obligation ends after proof | Worker execution is not qualified; no raw-state conditional branch |
| Attempt | actor | Existing isolated phase/terminal task | Scope finalization | Same source isolation; not execution evidence |
| Cleanup claim | Mutex<Bool> | claimTerminalCleanup | Immutable admitted-process lifetime | Same source isolation; not execution evidence |
