# RuntimeWorkerAcceptanceSourceRunner

## Purpose and Scope

`RuntimeWorkerAcceptanceSourceRunner` is the lightweight executable module
that crosses from a live checkout into the RT4.B verified-source phase. It
materializes one descriptor-verified snapshot and replaces itself with Bash
executing the exact script bytes retained by that snapshot.

Parent: [`Acceptance/RuntimeWorker/DESIGN.md`](../../DESIGN.md).

Children: none.

## Responsibilities and Boundaries

This module owns the fixed source-authority command-line modes, validation of
their positional arguments, the exact execution-script byte handoff, and the
scoped `execv` process replacement. It depends only on
`RuntimeWorkerAcceptanceSourceIdentity` plus the platform system libraries
needed for process replacement.

It does not own the runtime worker, Mojo authoring, bundle verification,
consumer execution, receipt construction, Git archive selection, or build
cache reuse. It cannot import `MojoRuntime`, `MojoRuntimeWorker`,
`MojoCommandCore`, or SwiftSyntax. Its live-only build products never enter the
verified evidence arena.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`RuntimeWorker Acceptance`](../../DESIGN.md) | parent | RT4.B bootstrap boundary | Invokes this executable before any evidence build. | A successful bootstrap is not an actual-host receipt. |
| [`SourceIdentity`](../RuntimeWorkerAcceptanceSourceIdentity/DESIGN.md) | depends on | Verified snapshot and retained script bytes | Supplies the only filesystem authority used here. | The runner must not reopen the script pathname. |

## Architecture

```text
live repository root R
    -> SourceIdentity no-follow snapshotter
    -> read-only private snapshot S + identity D + exact script Data
    -> validate fixed live Git root and caller arguments
    -> /bin/bash -c <exact Data> <fixed argv0> S liveGitRoot D arguments
```

## Contracts and Invariants

The source runner accepts only closed command modes. Snapshot execution
requires a destination named `acceptance-source`, an explicit live Git root,
the `--` delimiter, and script bytes that are valid UTF-8 without NUL. It passes
the snapshot root and digest as fixed positional arguments. No environment
variable can select a phase, source root, work directory, script path, or
cleanup target.

The unsafe process-replacement boundary owns every `strdup` allocation,
retains it until `execv` succeeds or returns, appends exactly one null argument
pointer, never lets a pointer escape, and frees every allocation exactly once
when `execv` fails. It validates NUL before allocation and reports a typed
failure containing the captured `errno`.

## Runtime Flows

```text
isolated live-only build arena GB
    -> source runner
    -> verify R / materialize S / capture D-bound script bytes
    -> exec verified script bytes
    -> script creates exact Git archive T and fresh evidence arena GP
```

## State, Ownership, and Lifecycle

The module holds no shared mutable state. Snapshot values and script `Data`
live only until process replacement. The live entrypoint supervisor owns the
private work root outside this executable's workload session; this executable
never removes it and never receives cleanup authority.

## Failure, Concurrency, and Constraints

Invalid arguments, invalid UTF-8 or NUL-bearing script bytes, allocation
failure, and `execv` failure are typed and nonzero. Source verification and
snapshot failures propagate without fallback. Operations are synchronous and
bounded by the SourceIdentity byte limits; no task or background process is
created before `execv`.

## Verification and Change Impact

Focused tests must reject malformed modes and prove the exact snapshot bytes,
fixed `argv0`, digest, and forwarded arguments. Script tests must prove forged
phase/work-root environment values cannot bypass this executable. A clean
macOS bootstrap build log must contain zero runtime, command, SwiftSyntax, and
SwiftCrypto/BoringSSL compilation. Linux must compile and link the same module
against the pinned conditional `Crypto` dependency. Any change to its modes or
argument order requires the parent script, closed source inventory, and actual
host evidence to be regenerated.
