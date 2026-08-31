# RuntimeWorkerAcceptanceSourceIdentity

## Purpose and Scope

`RuntimeWorkerAcceptanceSourceIdentity` is a standalone child module of the
RT4.B acceptance package. It
provides one public, read-only authority for identifying the repository source
that generated an acceptance run. It owns inventory expansion, path
normalization, descriptor-relative bounded regular-file reads, the versioned
aggregate digest, and materialization of a verified private source snapshot.

Parent: [`Acceptance/RuntimeWorker/DESIGN.md`](../../DESIGN.md).

Children: none. This module is built independently for the lightweight source
runner and as a dependency of the full acceptance controller.

## Responsibilities and Boundaries

This component owns:

- the literal algorithm identifier
  `sha256-path-nul-bytes-nul-v1`;
- the closed repository-relative file inventory;
- validation and sorting of regular, non-symlink files;
- no-follow traversal of every inventory path component from one retained root
  descriptor;
- per-file and aggregate byte limits;
- incremental SHA-256 framing and typed rejection of invalid input;
- a second-pass stability check and descriptor/path file-identity comparison;
- the public identity, verifier, and verified-snapshot protocols.
- a platform-equivalent SHA-256 backend: system `CryptoKit` on macOS and the
  pinned `Crypto` product on Linux.

It does not own repository mutation, source generation, compiler invocation,
process replacement, worker execution, receipt encoding, process control, or
a consumer-provided inventory. The caller supplies the repository root explicitly. The verifier
does not expose a file handle, arbitrary path authority, or a callback to the
consumer.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`RuntimeWorker Acceptance`](../../DESIGN.md) | parent | RT4.B source identity handoff | Uses this module for bootstrap, execution-runner, execution-start, and execution-end identity. | A source digest does not prove a bundle or host run by itself. |
| [`Source Runner`](../RuntimeWorkerAcceptanceSourceRunner/DESIGN.md) | used by | Verified snapshot and exact script bytes | Builds only over this module for the live bootstrap handoff. | Its live build products never enter the evidence phase. |
| [`Swift Mojo`](../../../../DESIGN.md) | indirect parent | Repository boundary | Provides the root whose selected source is identified. | The inventory is intentionally narrower than the entire repository. |

## Architecture

```text
explicit repository root
    -> retained no-follow root descriptor
    -> openat/fstatat no-follow traversal and closed inventory enumeration
    -> normalized root-relative UTF-8 paths
    -> UTF-8 byte lexicographic order
    -> descriptor-fixed bounded two-pass file reads
    -> same device/inode/size/time and path-reopen identity
    -> SHA-256(path + NUL + raw bytes + NUL)
    -> AcceptanceSourceIdentity
    -> source A / private snapshot B / source C equality
    -> read-only AcceptanceSourceSnapshot
    -> descriptor-read execution-script bytes matched to B
```

The public protocols expose synchronous value-producing verification and one
fresh-destination snapshot operation. The filesystem implementations are the
sole concrete implementations in this package. The returned value contains
the algorithm, expanded inventory, file records, total byte count, and
aggregate digest, so later receipt mappers can preserve the identity without
reimplementing it.

## Contracts and Invariants

The closed file inventory is exactly:

```text
Acceptance/RuntimeWorker/DESIGN.md
Acceptance/RuntimeWorker/Fixtures/Consumer/Sources/RuntimeWorkerAcceptanceConsumer/RuntimeWorkerAcceptanceConsumer.swift
Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift
Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/RuntimeWorkerAcceptanceModelInventory.swift
Acceptance/RuntimeWorker/Mojo/RuntimeWorkerAcceptanceModel/__init__.mojo
Acceptance/RuntimeWorker/Package.resolved
Acceptance/RuntimeWorker/Package.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceContract.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceController.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceError.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceProjectionOracle.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunConfiguration.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunReport.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptance/RuntimeWorkerAcceptanceRunnerError.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceRunner/RuntimeWorkerAcceptanceRunner.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/DESIGN.md
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/FileSystemRuntimeWorkerAcceptanceSourceIdentityVerifier.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/FileSystemRuntimeWorkerAcceptanceSourceSnapshotter.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptancePOSIX.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptanceSourceIdentity.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptanceSourceIdentityError.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptanceSourceIdentityVerifying.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptanceSourceSnapshot.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceIdentity/RuntimeWorkerAcceptanceSourceSnapshotting.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceRunner/DESIGN.md
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceRunner/RuntimeWorkerAcceptanceSourceRunner.swift
Acceptance/RuntimeWorker/Sources/RuntimeWorkerAcceptanceSourceRunner/RuntimeWorkerAcceptanceSourceRunnerError.swift
Acceptance/RuntimeWorker/SwiftMojo.json
Acceptance/RuntimeWorker/Tests/RuntimeWorkerAcceptanceTests/RuntimeWorkerAcceptanceSnapshotPackageLayout.swift
scripts/command-timeout.sh
scripts/runtime-worker-acceptance.sh
```

The verifier rejects a missing inventory file, an unexpected file or directory
below an owned fixture/source directory, a symlink at any path component, a
non-regular file, an unreadable file, an invalid path, or a file/total byte
limit violation. Expected directories are derived only from the ancestors of
the exact inventory files; hidden entries are not ignored. The repository root
itself must be a directory and must not be a symlink. Traversal starts at one
retained root descriptor and never resolves an inventory component through a
path-based follow operation.

Each path is normalized as a slash-separated, root-relative UTF-8 path. An
absolute path, an empty component, `.` or `..`, a backslash, NUL, malformed
UTF-8, or a non-ASCII path is rejected. The normalized paths are sorted by
their UTF-8 bytes, not by locale or Unicode collation.

For each sorted file, the SHA-256 state is updated in this exact order:

```text
UTF-8 path bytes, one NUL byte, raw file bytes, one NUL byte
```

File bytes are read in bounded chunks and never loaded without the configured
per-file and aggregate limits. The identity digest is lowercase hexadecimal
SHA-256. The public algorithm and inventory fields are immutable and must
match the verifier's constants exactly.

Each regular file is opened with no-follow semantics relative to its retained
parent descriptor. The opened descriptor must have the same device and inode
as the no-follow directory entry. Two complete bounded reads must produce the
same byte count and digest, pre/post descriptor metadata must remain stable,
and reopening the path must resolve to the same file identity. A mismatch is a
typed changed-during-read failure; path attributes alone are never sufficient.

Snapshot materialization accepts only a nonexistent destination under a
caller-owned private temporary root. It verifies source identity A, then opens
and reads every exact inventory file through the retained no-follow source
descriptor with the same per-file and aggregate bounds; it never performs a
recursive or path-following copy. It verifies snapshot identity B and source
identity C, requires `A == B == C`, makes the snapshot files and directories
read-only, then verifies B again. A partial snapshot is removed on failure and
never returned. Before returning, it reopens the one fixed execution-script
entry through the snapshot root descriptor, matches its byte count and SHA-256
to B, and returns those immutable bytes with the snapshot. The caller executes
those bytes rather than reopening a script pathname.

## Runtime Flows

```text
lightweight source runner built in isolated live-only arena GB
    -> snapshotter.materializeVerifiedSnapshot(source R, private S) produces D
    -> source runner replaces itself with bash -c over D-bound script bytes
    -> archive exact swift-mojo revision P into private read-only tree T
    -> execution runner built from S with dependency root T in fresh arena GP
    -> execution runner recomputes D before authoring
    -> model marker, explicit worker binding inventory, and consumer use only S
       with dependency root T
    -> verifier.sourceIdentity(at: S) before execution
    -> verifier.sourceIdentity(at: S) after execution
    -> reject any digest/algorithm/inventory mismatch
```

The verifier has no mutable process-wide state. Each call independently
enumerates and hashes the root. A caller may retain the returned value, but it
must not construct a replacement identity from a digest string alone.

## State, Ownership, and Lifecycle

The verifier borrows the caller's root URL for one synchronous call, retains
the root and nested descriptors only within scoped operations, and returns an
immutable value. The snapshotter owns a fresh destination until it either
returns a read-only verified snapshot with its fixed execution-script bytes or
removes the partial tree. All descriptors are closed before either call
returns; the bounded execution-script `Data` intentionally survives as the
later process-replacement input.

## Failure, Concurrency, and Constraints

`AcceptanceSourceIdentityError` is a closed, typed error. It distinguishes
invalid roots, missing inventory entries, unexpected entries, symlinks,
non-regular entries, unreadable files, invalid paths, per-file overflow,
aggregate overflow, descriptor/path identity changes, snapshot mismatch, and
snapshot cleanup/permission failures. Errors never produce a partial or
guessed identity. The synchronous implementations are safe to call
concurrently because they share no mutable state.

## Verification and Change Impact

Focused tests must prove exact framing, creation-order independence,
one-file content identity, path and missing/extra rejection, intermediate and
final symlink rejection, same-size path/inode replacement rejection,
non-regular and bound rejection, repeated-call determinism, source/snapshot
mismatch cleanup, and read-only snapshot behavior. They must also verify the
actual repository inventory and the public protocol/concrete implementation
path. Script tests must prove that only the verified snapshot and exact
archived production revision reach runner/model/consumer authoring, forged
phase/work-directory environment values cannot enter the verified flow, and
the executed script comes from the immutable bytes returned by the snapshotter.
Clean bootstrap logs must prove that this module and source runner do not build
`MojoRuntime`, `MojoRuntimeWorker`, `MojoCommandCore`, SwiftSyntax, or the
SwiftCrypto/BoringSSL source closure on macOS. Cross-platform tests must prove
that CryptoKit and Crypto produce the same canonical digest fixture.

Changing the algorithm literal, inventory, normalization, bounds, or returned
fields invalidates all RT4.C/RT4.D source-bound evidence and requires the
parent design and host handoff review to be repeated.
