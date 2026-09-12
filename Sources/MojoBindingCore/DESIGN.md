# MojoBindingCore

## Direct opaque resources

Validate opaque factory/operation declarations against the exact signatures in the linked contract. Operations reference a resource factory in the same package and session factory. Include factory, destroy and completion symbols in canonical identity; reject missing or mismatched relationships before generation.
The [Mojo ownership contract](../Mojo/DESIGN.md#direct-opaque-resources) owns lifecycle and admission guarantees.


## Scoped direct buffer contract (2026-09-12)

Direct borrowed Float32/Float64 signatures use `borrowing Span<Float/Double>`
and `inout MutableSpan<Float/Double>`. BindingCore validates these exact Swift
ownership forms and includes them in canonical binding identity. Array signatures
are replaced, without a compatibility dispatcher. Scalar/factory identities are
unchanged. ArtifactCore emits scoped pointer/count calls from these views; C ABI
payload layout remains typed pointer plus UInt64 element count. The generated
registry must not allocate, resize or materialize buffer payloads. Empty-buffer
and explicit Mojo-status failures retain their existing behavior. Regenerate
prepared artifacts and check actual macro-to-native execution before completion.


## Purpose and Scope

Parent: [package](../../DESIGN.md). No child design units. Own the binding source
model used by macro expansion and artifact generation.

## Responsibilities and Boundaries

Parse supported file-scope Swift declarations, validate external implementation
and session-factory relationships, and derive canonical binding/graph identities.
Do not execute caller expressions, invoke Mojo, import resources or select models.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Package](../../DESIGN.md) | parent | Product boundaries | Binding IR is package-internal | Static and worker products remain distinct |
| [ProtocolCore](../MojoRuntimeProtocolCore/DESIGN.md#resource-binding-signature) | depends on | Resource signature and canonical encoding | Numeric types/ranks and scalar schemas | Include the complete signature in implementation identity |
| [ArtifactCore](../MojoArtifactCore/DESIGN.md#resource-binding-authoring-and-native-call-boundary) | used by | Binding graph | Generates native adapters and manifests | Parsing is not endpoint execution proof |

## Architecture

```text
Swift declarations -> shared binding parser -> typed bindings + canonical graph
                                                -> macro expansion
                                                -> artifact generation
```

## Contracts and Invariants

Resource operation declarations take one `MojoRuntimeWorker` and return
`MojoRuntimeWorkerOperation` with `throws`. Their attribute requires external
package/function/sessionFactory literals and five literal arrays: argumentTypes,
inputTypes, inputRanks, resultTypes, outputTypes. Numeric types use unqualified
member literals. Rank values are decimal UInt16 literals. Input types and ranks
must have equal counts; all arrays fit UInt16. Duplicate, incomplete, unknown or
computed fields fail before identity generation.

Resource declarations retain the same factory/package relationship checks as
other session bindings. Their complete canonical signature contributes to the
implementation digest and thus the graph digest. A changed type, order or rank
must invalidate graph identity. Parameter names and algorithm meaning remain
outside the generic wire signature.

## Failure, Concurrency, and Constraints

Binding values are immutable Sendable records. Source parsing and canonicalization
are synchronous and do not retain borrowed pointers. Invalid syntax, unsupported
signatures and broken factory relationships throw typed binding errors.
Resource macro expansion and endpoint generation currently reject explicitly
until their invocation implementation is connected; source-model acceptance does
not authorize publishing an executable resource worker.

## Verification and Change Impact

[Binding tests](../../Tests/MojoBindingCoreTests/MojoBindingCoreTests.swift) parse
real source files, round-trip typed metadata, mutate each signature category and
reject malformed authoring. Recheck macro expansion, generated native adapters,
manifest/projection identity and public worker admission when contracts change.
