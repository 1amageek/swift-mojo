# ADR-0014: Static artifact attestation

- Status: Accepted
- Date: 2026-08-30
- Scope: Read-only identity of the build-verified, statically linked artifact

## Context

Consuming packages need to compare an exact prepared artifact identity with
their own pinned model contract before creating a model session. Reading a
manifest at runtime would make the filesystem a second authority. Loading a
library with `dlopen` or resolving symbols with `dlsym` would contradict the
package's static-first application contract and expose raw lifetime concerns.

The build verifier already validates source inventory, configuration, manifest,
generated source, source map, every native artifact tree, each selected archive,
and all manifest binding records. The generated Registry already checks the
actual linked ABI version, input-graph identifier, and complete binding
membership before dispatch.

## Decision

`Mojo` exposes an immutable `MojoStaticArtifactAttestation` value and an
`@mojoStaticArtifactAttestation` body macro. The macro expands a
consumer-declared function into
a call to its target's generated Registry. The Registry projects exact values
from the verified manifest and compile-destination slice and returns them only
after its linked preflight succeeds.

```text
verified manifest + selected static slice
    -> generated immutable fields
linked ABI/input graph/all bindings
    -> cached preflight
both valid
    -> attestation returned
```

The public type has no public initializer and no decoding conformance. Its
construction API and preflight helper are generated-code SPI. The attestation
contains manifest schema and ABI versions, compiler and generation-pipeline
identity, target/module identity, source/input graph identities, generated
source and source-map digests, aggregate and selected native-artifact identity,
selected target/slice/archive identity, and exact binding records.

The attestation is provenance evidence only. It does not claim device
availability, actual accelerator selection, session creation, kernel execution,
performance, or safety. Consuming packages must establish those independently.

## Rejected alternatives

| Alternative | Reason |
|---|---|
| Runtime manifest read | Creates a mutable filesystem authority after build verification. |
| Public dynamic loader | Reverses the static-first boundary and exposes symbol/lifetime policy. |
| Caller-provided identity strings | Self-reporting cannot prove the linked artifact. |
| Public attestation initializer or `Decodable` | Allows ordinary application code to construct an indistinguishable value. |
| Expose `__SwiftMojoGeneratedBindings` | Couples application source to an implementation name rather than a stable macro contract. |

## Consequences

Registry generation becomes part of the attestation schema and must invalidate
the generation-pipeline digest when changed. Prepared integration artifacts
must be regenerated. Generated code imports the construction SPI, while normal
consumer code uses only the public macro and immutable value. Legacy artifacts
without complete input-graph/source-map identity remain invocable but cannot
produce a complete attestation.

## Verification

Tests must prove exact manifest-to-value projection, macro expansion and invalid
signature diagnostics, actual static integration access, and that ABI,
input-graph, or any missing binding prevents the guarded operation from running.
Build-verifier corruption tests remain the evidence for source, configuration,
manifest, generated source/source map, archive, and artifact-tree mutation.
