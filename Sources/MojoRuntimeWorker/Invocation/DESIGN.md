# Resource Invocation

## Purpose and Scope

Parent: [Worker](../DESIGN.md). No children. Own admission of typed input views
into bounded resource request metadata and retained transfer segments.

## Responsibilities and Boundaries

This component assigns handle ordinals and copied-body offsets, deduplicates
buffer owners and applies the verified operation's capacities. Input owns
producer lifetime and layout construction. ProtocolCore owns wire validation and
encoding. Native importers grant shared storage eligibility. No model semantics,
repacking, implicit copied fallback or mapping cache belongs here.

## Related Designs

| Design | Relationship | Contract Used | Summary | Cautions |
|---|---|---|---|---|
| [Worker](../DESIGN.md) | parent | Verified invocation and completion | Selects and retains a prepared invocation | Preparation alone is not execution evidence |
| [Input](../Input/DESIGN.md) | depends on | View and package storage projection | Grants immutable host source or retained shared descriptor | Borrow descriptors; never duplicate sender handles here |
| [ProtocolCore](../../MojoRuntimeProtocolCore/DESIGN.md) | depends on | Resource descriptors and limits | Canonical validation/encoding | Revalidate each view with binding limits |
| [Lifecycle](../Lifecycle/DESIGN.md) | used by | Retained owners and aggregate bytes | Receives uncertain reader obligations | Transfer owners before releasing local protocol state |

## Architecture

```text
verified capacities + arguments + typed views
  -> identity-deduplicated owners
  -> copied offsets / dense shared ordinals
  -> validated resource control + borrowed transfer segments
  -> transport -> terminal response or retained cleanup
```

## Contracts and Invariants

Host-source construction explicitly selects copied transport; native import
selects required shared transport. Preparation preserves that choice.
Distinct views of one owner share its ordinal or payload range. Different owner
objects remain distinct even if the caller imported the same native allocation
more than once. Copied regions are aligned to the greatest element alignment
used by their views; padding is at most seven bytes per region. Only metadata is
materialized. Host source byte callbacks are not invoked during preparation.
Input count is checked before building bridge-owned owner tables. ProtocolCore
revalidates rank, extent, arithmetic and aggregate capacities before control
encoding. Failed preparation grants no transfer authority.

## State, Ownership, and Lifecycle

Prepared requests are immutable Sendable values holding the unique input owners,
borrowed sender descriptors and copied regions. No pointer escapes a source
borrow. The eventual transport must validate each host borrow size against its
owner and send padding explicitly; it must not build a combined pixel payload.
The parent retains the prepared owners through accepted completion or confirmed
reader termination. No background work or mutable state is created here.

## Failure, Concurrency, and Constraints

Unaligned layouts, overflow, excessive counts and binding capacities fail before
transfer. Metadata work depends on input count/rank, not input byte size. Native
mapping, rights commitment, cancellation and result acceptance are separate
transport/worker obligations and remain required before public invocation qualification.

## Verification and Change Impact

Preparation tests must exercise actual public buffer/view constructors, aliases,
mixed copied/shared inputs, copied alignment, revalidation under stricter limits,
zero eager borrow and failed bounds. Public invocation and native worker numerical
fixtures separately prove that prepared requests are selected and executed.

The transport sends rights only with the first positive sendmsg result, then
sends borrowed copied regions without materializing a combined input body.
A result may arrive in fragments; declared schema, counts and total bytes are
validated before output allocation. Result-side rights are rejected and closed.
The cancellation gate and absolute deadline apply during all partial I/O.
ResourceTransportTests uses an independent native-socket peer to map shared
aliases, compute strided numerical results and reject malformed responses.
This proves transport behavior, not generated Mojo execution or public session
selection; those remain parent integration gates.

### Scalar argument contract

`MojoInvocationArguments` owns an immutable ordered list of fixed-width numeric
values. Each value encodes little-endian bytes with no native struct padding;
floating-point values preserve their IEEE bit patterns. The type sequence, not
the values, defines the argument schema. [ProtocolCore](../../MojoRuntimeProtocolCore/DESIGN.md#scalar-value-schema)
owns its canonical digest. Binding identity owns parameter names and meaning.
The list is bounded to UInt16 count before schema construction. Invocation
admission checks the binding's schema and byte budget before allocating encoded
argument storage. The generated binding will supply that expected schema; callers
cannot authorize a different schema by supplying a matching-looking payload.
Tests cover all numeric types, signed boundaries, NaN/signed-zero bit patterns,
order-sensitive schema identity and rejection before encoding.
