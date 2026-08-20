# Roadmap

## 1. Overview

各Phaseは独立した成果物とverification gateを持ちます。構文の見た目ではなく、実際のcompiler、artifact、link、runtime、failure behaviorが閉じた時点で完了とします。

| Phase | Outcome | Status |
|---|---|---|
| 0 — Foundation | 要件、責務境界、package skeleton | Complete |
| 1 — Exact-syntax scalar PoC | `@mojo { mojo {} }` から実Mojo静的実行 | Hardening implemented; revalidation pending |
| 2 — DSL and diagnostics | scalar DSL拡張、source-located diagnostics、inspection | Planned |
| 3 — Types and ownership | buffers、strings、records、error envelope | Planned |
| 4 — Async and callbacks | cancellation、completion、shutdown、reverse bridge | Research/Planned |
| 5 — Model packages and distribution | external Mojo packages、multiple slices/targets、remote artifacts、CI matrix | Planned |
| 6 — GPU compute | device/buffer/event/transfer contracts | Research |
| 7 — Full inline Mojo syntax decision | custom input/preprocessor/compiler integration | Research |

```mermaid
flowchart LR
    P0["Phase 0<br/>Foundation"] --> P1["Phase 1<br/>Exact scalar PoC"]
    P1 --> P2["Phase 2<br/>DSL + diagnostics"]
    P2 --> P3["Phase 3<br/>Types + ownership"]
    P3 --> P4["Phase 4<br/>Async + callbacks"]
    P3 --> P5["Phase 5<br/>Model packages + distribution"]
    P4 --> P6["Phase 6<br/>GPU compute"]
    P5 --> P6
    P2 --> D{"Need arbitrary<br/>Mojo grammar?"}
    D -->|No| P3
    D -->|Yes| P7["Phase 7<br/>Full inline syntax decision"]
    P7 --> P3
```

## 2. Phase 0 — Foundation

**Estimate:** 1–2 days

**Status:** Complete

Deliverables:

- Swift Package、macro、runtime/tooling責務の初期分離。
- requirements、design、philosophy、roadmap。
- fake successを作らないerror contract。
- local Swift/Xcode/Mojo capabilityの記録。

Phase 0で作った旧dynamic PoCは、Phase 1の理想的な静的経路と競合したため最終構成には残していません。初期repositoryでありrelease済み互換性がないため、壊れたdeprecated APIとして温存しませんでした。

## 3. Phase 1 — Exact-syntax scalar PoC

**Estimate:** 1–2 weeks

**Status:** G1–G8のbaseline evidenceあり。G9 hardening実装後のarm64 macOS revalidation pending

Target usage:

```swift
@mojo
func add(_ a: Int32, _ b: Int32) -> Int32 {
    mojo {
        return a + b
    }
}
```

### G1 — Shared semantic IR

**Artifact:** `MojoBindingCore`

**Status:** Implemented; current hardening revalidation pending

- SwiftSyntaxからP1 signature/bodyを解析。
- allowlisted operationだけをIRへ格納。
- full ABI/implementation/source graph digestとruntime IDを生成。
- formatting不変、implementation変更、unsupported expression、duplicate/no bindingを検証。

### G2 — Exact body macro

**Artifact:** public argument-free `@mojo` + `MojoBodyMacro`

**Depends on:** G1

**Status:** Implemented; current hardening revalidation pending

- 元bodyをcanonical binding IDを使うSwift thunkへ置換。
- macro argument、unsupported declaration/bodyを拒否。
- macro内でfile/process I/Oを行わない。

### G3 — Deterministic Mojo source generation

**Artifact:** `MojoStaticSourceRenderer`

**Depends on:** G1

**Status:** Implemented; current hardening revalidation pending

- fixed ABI version/source graph/membership/dispatcher exportsを生成。
- IR operationからMojo expressionを生成し、foreign textをpassthroughしない。
- C headerとmodule mapを固定化。
- Swift thunkはchecked `Int32` overflowをdispatcher前に拒否。
- P1 source scannerはconditional compilation内のbindingを拒否。

### G4 — Real static artifact preparation

**Artifact:** `swift-mojo prepare`、object、archive、XCFramework

**Depends on:** G3

**Status:** Implemented; current hardening revalidation pending

- Mojo 1.0 `--emit object` を実行。
- explicit target triple/CPU。
- schema 3 manifest、generation pipeline identity、XCFramework tree digest。
- output-scoped interprocess lock、typed lease、versioned marker、staging、backup/restore transaction。
- complete cache matchでmtimeを変えず再利用。
- subprocessはdedicated process group、deadline、TERM/KILL/reapを持つ。

### G5 — Artifact verifier

**Artifact:** `swift-mojo verify` + generated static Registry

**Depends on:** G1、G4

**Status:** Implemented; current hardening revalidation pending

- schema、ABI、compiler metadata、target、source graph、bindingsを照合。
- XCFramework全regular fileのcanonical digestを照合。
- stale source、wrong target、corrupt archive/header、missing artifact/manifestを拒否。

### G6 — SwiftPM/Xcode build integration

**Artifact:** `MojoBuildPlugin`

**Depends on:** G2、G5

**Status:** Implemented; current hardening revalidation pending

- pluginはsource-built executableを使う通常build commandとしてverifyを実行。
- Swift sources、manifest、XCFramework rootと全descendant file/directoryをrequired inputsへ登録。
- Registryだけをplugin work directoryへ生成。
- successful fixture returns `42`; wrong target/stale/missing state stops build。
- warm buildでheader/archiveを直接改変してもverifierを再実行。

`prebuildCommand` はsourceからbuildしたexecutableをSwiftPMが拒否することを実証したため採用していません。

### G7 — Developer setup and repository workflow

**Artifact:** package-layout CLI、safe `init`、committed example

**Depends on:** G4、G6

**Status:** Implemented; current hardening revalidation pending

- `--package-root` / `--target` でrecursive Swift source discovery。
- `Package.swift` とtarget source directoryを検証。
- bootstrap binary targetを生成。
- `init` 再実行でprepared artifactを保持。
- unmanaged/incomplete directoryを拒否。
- fresh cloneのSwiftPM graphを成立させるため `Generated/<Target>` をcommit対象化。

### G8 — End-to-end baseline proof

**Artifact:** acceptance evidence and executable

**Depends on:** G1–G7

**Status:** Previous baseline complete; current hardening tree requires rerun

- real Mojo `1.0.0 (ed45d567)` compile。
- Xcode build + plugin + macro + static link。
- `add(20, 22) == 42`。
- final Mach-Oに4つのfixed ABI symbols。
- Mojo dylib dependencyなし。
- arm64 Debug Xcode archive成功。
- archiveから別directoryへcopyしたexecutableも `42`。
- generic universal archiveはunsupported x86_64を明示的に拒否。
- unit、macro、compiler、artifact、plugin integrationの23 testsをbounded `xcodebuild test` で実行した履歴。

### G9 — Correctness and developer-experience hardening

**Artifact:** checked semantics、generation identity、incremental leaf tracking、interprocess transaction、bounded process owner、real-Mojo acceptance test

**Depends on:** G1–G8

**Status:** Implemented; execution pending

- checked `Int32` overflowとconditional compilation rejection。
- generation component versionsを合成したpipeline digestでcacheとverifyをinvalidate。
- XCFramework内部のfile overwriteとdirectory entry変更をbuild graphへ反映。
- cache readからcommitまでをinterprocess lockで直列化。
- compiler/build subprocessをprocess group単位でtimeout、terminate、kill、reap。
- 通常30 testsと、`SWIFT_MOJO_REAL_ACCEPTANCE=1`で有効になるreal Mojo testを定義。
- real Mojo testはprepare、plugin、macro、static link、`42`、overflow trapを同じartifactで検証。

G9は実装のみではcompleteにしません。通常suiteとreal Mojo suiteを実行し、warm nested-artifact mutation、concurrent output access、timeout後のdescendant消滅を観測してからP1全体を再びCompleteへ戻します。

Cold Release archiveはSwiftSyntaxのhost-side compileがボトルネックとなり、2回の120秒制限内には完了しませんでした。P1 acceptanceはDebug archiveで満たしていますが、Release cold-build時間はPhase 2で計測・改善するdeveloper-experience課題です。

## 4. Phase 2 — DSL expansion and diagnostics

**Estimate:** 3–6 weeks

**Depends on:** Phase 1

Candidate semantics:

- numeric literals and more arithmetic operators。
- immutable local bindings。
- comparison and explicit conditional expressions/statements。
- bounded loops with statically understood ownership。
- generated Mojo inspection command。
- Mojo compiler diagnosticからSwiftSyntax rangeへのsource map。

Verification loop:

```mermaid
flowchart LR
    H["Define one node's<br/>typed semantics"] --> R["Reference Mojo fixture"]
    R --> D["Differential success/failure tests"]
    D --> U["Update IR/lowering confidence"]
    U --> C{"All boundaries agree?"}
    C -->|No| H
    C -->|Yes| N["Admit node to public DSL"]
```

1 loopは0.5–2日を想定します。accepted nodeのsuccess、overflow/edge、unsupported composition、diagnostic rangeが一致したときだけ収束です。時間上限だけでcompleteにはしません。

## 5. Phase 3 — Types, ownership, and errors

**Estimate:** 4–8 weeks

**Depends on:** Phase 2

Deliverables:

- fixed-width scalar matrix。
- borrowed/owned contiguous buffers。
- UTF-8 string views。
- versioned records。
- status + out-value + owned diagnostic error envelope。
- owner/lease/borrow APIsとexactly-once deallocation。

Verification:

- safe reference implementationとのdifferential tests。
- bounds、alignment、overflow、aliasing、deallocation failure tests。
- allocation/copy countとperformance budget。
- Address Sanitizer等、対象環境で利用できるsanitizer。

## 6. Phase 4 — Async and callbacks

**Estimate:** 4–8 weeks

**Depends on:** Phase 3

Deliverables:

- async operation handle、completion、cancel、release。
- continuation single-resume state machine。
- shutdownを持つstream/callback owner。
- optional Mojo-to-Swift callbackとcontext lifetime。
- actor/Mutex isolation matrix。
- Swift export capabilityのtoolchain gate。

Verification:

- complete/cancel、shutdown/callback、owner release/reentry races。
- Thread Sanitizer where available。
- callback actor/executor hop behavior。
- Native/WASM/Embeddedで共有状態契約を弱めないcompile/runtime matrix。

## 7. Phase 5 — Mojo model packages and multi-target distribution

**Estimate:** 6–12 weeks

**Depends on:** source-graph work may start after Phase 2; complete distribution acceptance depends on Phase 3 and may run beside Phase 4 after ABI freeze

Deliverables:

- model implementationを独立したSwift Packageとして表すpackage/source manifest。
- `Mojo/<Package>/__init__.mojo` と全moduleを同じbinding/source graphへ統合。
- generated ABI entry moduleからMojo packageをimportし、declared bindingsをexport。
- model-specific Swift APIとMojo sourceとartifactを結ぶcompatibility manifest。
- multiple Mojo-enabled targets without generated module collision。
- arm64/x86_64 and future Linux slice-aware artifact manifest。
- Apple XCFramework adapterと、SwiftPMの実在するlink capabilityに基づく非Apple artifact adapterの分離。
- release/cache identity including target features。
- remote artifact bundle or package distribution workflow。
- signed/reproducible generated artifact policy。
- installed CLI distribution and version compatibility diagnostics。
- model weightsをcode artifactから分離するresolver/revision/digest contract。

Verification:

- real external Mojo packageを変更するとprepare cacheとconsumer verificationがinvalidateする。
- source package、Swift binding、manifest、native artifactのいずれかを単独改変するとbuildが失敗する。
- model authorはpinned Mojo compilerでprepareでき、clean consumerはMojo compilerなしでbuild/link/runできる。
- clean clone on every supported destination。
- universal archive and relocated executable tests。
- missing/wrong slice failure。
- artifact/source/compiler compatibility matrix。
- small deterministic model fixtureでload/inference successとwrong weight revision/digest failureを確認する。

## 8. Phase 6 — GPU compute

**Estimate:** 6–12+ weeks

**Depends on:** Phase 3; async portions depend on Phase 4; packaged model acceptance depends on Phase 5

Deliverables:

- backend/device/accelerator capability model。
- explicit host/device/shared buffer ownership。
- queue/stream/event dependency model。
- transfer observability。
- accelerator-aware artifact cache。
- CPU reference path for correctness comparison。

SwiftUI shader modifiers、view rendering、scene lifecycleはこのPhaseにも含みません。

## 9. Phase 7 — Full inline Mojo syntax decision

**Estimate:** 4–12 weeks for decision and prototype

**Trigger:** Real code requires Mojo grammar outside the Swift-parseable DSL

Prototype candidates:

1. `.swiftmojo` custom source producing derived Swift and Mojo。
2. Swift compiler driver preprocessing wrapper。
3. upstream Swift parser/compiler integration proposal。
4. compiler fork only if maintenance cost is justified。

Decision criteria:

- Xcode indexing、completion、source diagnostics。
- SwiftPM compatibility and distribution。
- one source of truth and incremental build behavior。
- Swift release追従cost。
- whether Phase 5 external Mojo model packages already satisfy full-language users。

Phase 5のexternal `.mojo` packageで十分なら、inlineはSwift-parseable DSLに限定します。arbitrary inline grammarのためだけにcompiler integration costを負いません。

## 10. Critical path and bottlenecks

```mermaid
flowchart LR
    P1["P1 proven"] --> P2["DSL semantics"] --> P3["Ownership ABI"]
    P3 --> P4["Async/callback"] --> P6["GPU"]
    P3 --> P5["Model packages + distribution"] --> P6
    P2 --> Decision["Full inline syntax demand proof"] --> P7["Integration decision"]
    P7 --> P3
```

主critical pathは `DSL semantics -> ownership ABI -> model package distribution -> GPU-capable model runtime` です。最大のbottleneckは構文生成ではなく、ownership/error/device semanticsと、compiler-free consumer artifactの実証です。async/callbackとdistributionはownership ABIが安定した後に並行化できます。GPU Phaseは両方の成果を統合します。arbitrary inline syntax integrationは需要の立証前にcritical pathへ入れません。
