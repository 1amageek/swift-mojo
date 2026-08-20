# ADR-0005: Target-scoped static frameworks

- Status: Accepted; remote multi-target acceptance pending
- Date: 2026-08-20
- Scope: Apple XCFramework packaging for multiple Mojo-enabled Swift targets

## Context

Target-scoped archive、module、and C symbol names prevent link-level identity collisions. They do not prevent an Xcode build-product collision when multiple library-style XCFrameworks publish `Headers/module.modulemap`. `ProcessXCFramework` copies those header trees into one product `include` directory, so two otherwise independent binary targets both claim the same output path.

This is an artifact-layout problem. Build ordering、parallelism limits、or retry behavior cannot make two producers of the same output valid.

## Decision

Each platform/variant group is packaged as a target-scoped static framework inside its XCFramework:

```text
SwiftMojo_<Target>_ABI.xcframework/
└── <platform-slice>/
    └── SwiftMojo_<Target>_ABI.framework/
        ├── SwiftMojo_<Target>_ABI   # static universal archive
        ├── Headers/
        │   └── SwiftMojo_<Target>_ABI.h
        ├── Modules/
        │   └── module.modulemap
        └── Info.plist
```

`MojoStaticFrameworkLayout` owns this layout. The preparer and bootstrap initializer create it、the XCFramework inspector requires its exact metadata、and build/release verification checks and hashes its binary and complete tree. The framework module map uses a target-scoped framework module and umbrella header.

The binary remains a static archive. This decision adds no runtime lookup、dynamic dependency、call indirection、buffer copy、or allocation to the Mojo invocation path.

## Invariants

| Concern | Required invariant |
|---|---|
| Module identity | framework、Clang module、header、binary、and Swift binary target are target-scoped |
| Linkage | framework binary is a static archive with the prepared Apple architectures |
| Metadata | XCFramework `LibraryPath` and `BinaryPath` identify the target-specific framework; `HeadersPath` is absent |
| Integrity | framework metadata、module map、header、and archive are included in the canonical artifact digest |
| Performance | generated dispatcher and direct C ABI remain unchanged |

## Alternatives considered

| Alternative | Decision |
|---|---|
| Serialize or retry XCFramework processing | Rejected; it does not resolve duplicate output ownership |
| Keep library XCFrameworks and nest or rename module maps | Rejected; it relies on noncanonical implicit Clang module discovery and does not give each binary target a distinct Xcode product |
| Remove the C module and use underscored Swift symbol declarations | Rejected; it would replace a public C interface with unstable compiler behavior |
| Merge every Mojo-enabled target into one package-wide artifact | Rejected; it couples independent target lifecycles、invalidates unrelated artifacts、and weakens target ownership |
| Use dynamic frameworks | Rejected; runtime loading and distribution semantics are unnecessary for the current static contract |

## Acceptance

- A real static-framework prototype imported the generated C module and executed its static ABI function.
- The committed integration fixture is regenerated as a universal arm64/x86_64 static framework and passes the normal Xcode package suite.
- Completion requires the remote two-target workflow to prepare、link、and execute two independent Mojo-enabled targets in one consumer.

## References

- [ADR-0001](ADR-0001-STATIC-PREPARE-PIPELINE.md)
- [ADR-0003](ADR-0003-RELEASE-ARTIFACT-SETS.md)
