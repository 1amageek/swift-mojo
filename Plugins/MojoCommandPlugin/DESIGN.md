# MojoCommandPlugin

## Purpose and Scope

`MojoCommandPlugin` is the command-plugin child module of the
[`swift-mojo` package](../../DESIGN.md). It converts package-author commands
into one canonical `swift-mojo` invocation while retaining SwiftPM package and
target authority over package-mode source selection.

Parent: [`swift-mojo`](../../DESIGN.md).

Children: none.

## Responsibilities and Boundaries

This module owns command-plugin argument admission, package-root injection,
source-target resolution, canonical binding-source inventory injection, and
the lifetime of the one `swift-mojo` tool process it starts.

It does not parse bindings, read `SwiftMojo.json`, compile Mojo, prepare or
verify artifacts, select hardware, load a runtime, or define model semantics.
Those responsibilities remain in `MojoCommandCore`, `MojoArtifactCore`, and
their lower-level dependencies. It never invents a source file or falls back
from an invalid explicit inventory to SwiftPM's compiled-source inventory.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [`swift-mojo`](../../DESIGN.md) | parent | Package authoring boundary | Indexes this command plugin and the `swift-mojo` tool it invokes. | A plugin command is authoring evidence, not runtime or device evidence. |
| [`MojoArtifactCore`](../../Sources/MojoArtifactCore/DESIGN.md) | depends on indirectly | Canonical binding graph and artifact transactions | Consumes the canonical package root and source inventory through `MojoCommandCore`. | Raw `--source` and `--source-root` remain plugin-owned in package mode. |
| [`RuntimeWorker Acceptance`](../../Acceptance/RuntimeWorker/DESIGN.md) | used by | Detached worker binding inventory | Uses one target-owned, build-excluded binding declaration file to author a worker in the same Acceptance package graph. | The explicit file is an authoring schema input and is not a generated Swift runtime implementation. |

## Architecture

```text
package author arguments
    -> command/source-mode admission
    -> SwiftPM target lookup
        -> default: SwiftPM compiled Swift source inventory
        -> worker-only switch: validated exact --binding-source inventory
    -> canonical --package-root / --source-root / --source arguments
    -> one exact swift-mojo tool process
```

## Contracts and Invariants

For package commands that consume Swift bindings, the plugin resolves exactly
one `--target`. Every command normally passes the `.swift` files reported by
SwiftPM for that source target, sorted by path. Only
`runtime-worker-prepare --target` accepts one or more `--binding-source`
options; for that command the explicit values replace the default inventory
and are themselves removed before tool invocation. `prepare`, `inspect`,
`release`, `runtime-library-prepare`, and every other command retain the exact
SwiftPM source inventory as their sole source authority.

Every explicit binding source must be a nonempty `.swift` path below the
selected target directory. The selected target root itself is canonicalized;
the source must preserve the same relative suffix after symlink resolution, be
a regular non-symlink file, and have a unique canonical path. This permits a
package opened through one symlinked root without permitting a symlink inside
the selected target tree. The plugin sorts the exact explicit inventory before
injecting it. This authority switch prevents any declaration outside that
closed worker schema from silently entering the generated binding table.
An absolute path or a package-root-relative path is accepted; target-directory
containment is checked after normalization with a path-component boundary.

`--binding-source` is accepted only by `runtime-worker-prepare --target`.
Package authors cannot pass `--source` or `--source-root` directly because
those options are the canonical handoff from this plugin to the tool. Missing
values, duplicate target options, missing targets, empty inventories, invalid
files, unsupported-command use, and nonzero tool termination are typed plugin
failures.

## Runtime Flows

```text
performCommand
    -> remove and validate plugin-only binding-source options
    -> inject package root when the command requires it
    -> resolve selected SourceModuleTarget
    -> select and canonicalize exact binding sources
    -> append source root and each source
    -> run swift-mojo and wait for exact termination
```

## State, Ownership, and Lifecycle

The plugin has no retained mutable state. It borrows SwiftPM's `PluginContext`
for one invocation, constructs one immutable forwarded argument array, starts
one `Process`, waits for that exact process, and then returns. Source URLs do
not escape the invocation.

## Failure, Concurrency, and Constraints

Source inventory validation finishes before the tool starts. Any invalid
explicit entry rejects the entire command; partial inventories and fallback
are not allowed. The plugin does not run commands concurrently and does not
own the compiler descendants created later by `swift-mojo`.

The explicit inventory exists for worker-only schema declarations that are
intentionally excluded from ordinary Swift compilation. It must not be used to
claim that the selected files form a compiled application API.

## Verification and Change Impact

The command-plugin explicit-inventory acceptance proves that a buildable marker
target can author one excluded binding source, while outside-target, symlink,
duplicate, missing-value, and reserved raw-source inputs fail before the tool
accepts them. The normal package command path continues to prove SwiftPM source
discovery. RT4.B additionally proves the explicit inventory in the real worker
prepare path and then builds the public-only consumer in the same package graph.

Changes to option parsing, target containment, source normalization, or tool
argument injection require both the focused command-plugin acceptance and the
RT4.B script/actual-host authoring path. Changes to binding semantics or
artifact generation belong to their owning modules and require their tests.
