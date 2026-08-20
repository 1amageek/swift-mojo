# Roadmap

## 1. Overview

各Phaseは独立した成果物とverification gateを持ちます。構文の見た目ではなく、実際のcompiler、artifact、link、runtime、failure behaviorが閉じた時点で完了とします。

| Phase | Outcome | Status |
|---|---|---|
| 0 — Foundation | 要件、責務境界、package skeleton | Complete |
| 1 — Exact-syntax scalar PoC | direct `@mojo func ... { return ... }` から実Mojo静的実行 | Complete for the macOS scalar contract |
| 2 — DSL and diagnostics | scalar DSL拡張、source-located diagnostics、inspection | Inspection verified; real diagnostic mapping and DSL expansion planned |
| 3 — Types and ownership | buffers、strings、records、error envelope | First borrowed `Float` slice verified through real runtime; allocation/copy and sanitizer gates remain |
| 4 — Async and callbacks | cancellation、completion、shutdown、reverse bridge | Research/Planned |
| 5 — Model packages and distribution | external Mojo packages、multiple slices/targets、remote artifacts、CI matrix | External package、universal slices、clean consumer、and two-target linking verified; model/distribution work remains |
| 6 — GPU compute | device/buffer/event/transfer contracts | Research |
| 7 — Full inline Mojo syntax decision | custom input/preprocessor/compiler integration | Research |

```mermaid
flowchart LR
    P0["Phase 0<br/>Foundation"] --> P1["Phase 1<br/>Exact scalar PoC"]
    P1 --> P2["Phase 2<br/>DSL + diagnostics"]
    P1 --> P3["Phase 3<br/>Types + ownership"]
    P3 --> P4["Phase 4<br/>Async + callbacks"]
    P3 --> P5["Phase 5<br/>Model packages + distribution"]
    P4 --> P6["Phase 6<br/>GPU compute"]
    P5 --> P6
    P2 --> D{"Need arbitrary<br/>Mojo grammar?"}
    D -->|No| K["Keep Swift-parseable<br/>DSL subset"]
    D -->|Yes| P7["Phase 7<br/>Full inline syntax decision"]
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

**Status:** Complete for the current macOS `(Int32, Int32) -> Int32` contract

Target usage:

```swift
@mojo
func add(_ a: Int32, _ b: Int32) -> Int32 {
    return a + b
}
```

### G1 — Shared semantic IR

**Artifact:** `MojoBindingCore`

**Status:** Verified

- SwiftSyntaxからP1 signature/bodyを解析。
- allowlisted operationだけをIRへ格納。
- full ABI/implementation/source graph digestとruntime IDを生成。
- formatting不変、implementation変更、unsupported expression、duplicate/no bindingを検証。

### G2 — Exact body macro

**Artifact:** inline/external `@mojo` + `MojoBodyMacro`

**Depends on:** G1

**Status:** Verified

- 元bodyをcanonical binding IDを使うSwift thunkへ置換。
- unknown macro argument、unsupported declaration/bodyを拒否。
- macro内でfile/process I/Oを行わない。

### G3 — Deterministic Mojo source generation

**Artifact:** `MojoStaticSourceRenderer`

**Depends on:** G1

**Status:** Verified

- fixed ABI version/source graph/membership/dispatcher exportsを生成。
- IR operationからMojo expressionを生成し、foreign textをpassthroughしない。
- C headerとmodule mapを固定化。
- Swift thunkはchecked `Int32` overflowをdispatcher前に拒否。
- P1 source scannerはconditional compilation内のbindingを拒否。

### G4 — Real static artifact preparation

**Artifact:** `swift package --disable-sandbox --allow-writing-to-package-directory mojo prepare`、object、archive、XCFramework

**Depends on:** G3

**Status:** Verified

- Mojo 1.0 `--emit object` を実行。
- explicit target triple/CPU。
- schema 4 manifest、target identity、canonical generated Mojo/source map digests、generation pipeline identity、XCFramework tree digest。
- output-scoped interprocess lock、typed lease、versioned marker、staging、backup/restore transaction。
- complete cache matchでmtimeを変えず再利用。
- subprocessはdedicated process group、deadline、TERM/KILL/reapを持つ。

### G5 — Artifact verifier

**Artifact:** `swift-mojo verify` + generated static Registry

**Depends on:** G1、G4

**Status:** Verified

- schema、ABI、compiler metadata、target、source graph、bindingsを照合。
- XCFramework全regular fileのcanonical digestを照合。
- stale source、wrong target、corrupt archive/header、missing artifact/manifestを拒否。

### G6 — SwiftPM/Xcode build integration

**Artifact:** `MojoBuildPlugin`

**Depends on:** G2、G5

**Status:** Verified

- pluginはsource-built executableを使う通常build commandとしてverifyを実行。
- Swift sources、manifest、XCFramework rootと全descendant file/directoryをrequired inputsへ登録。
- Registryだけをplugin work directoryへ生成。
- successful fixture returns `42`; wrong target/stale/missing state stops build。
- warm buildでheader/archiveを直接改変してもverifierを再実行。

`prebuildCommand` はsourceからbuildしたexecutableをSwiftPMが拒否することを実証したため採用していません。

### G7 — Developer setup and repository workflow

**Artifact:** package-layout CLI、safe `init`、committed example

**Depends on:** G4、G6

**Status:** Verified

- `--package-root` / `--target` でrecursive Swift source discovery。
- `Package.swift` とtarget source directoryを検証。
- bootstrap binary targetを生成。
- `init` 再実行でprepared artifactを保持。
- unmanaged/incomplete directoryを拒否。
- fresh cloneのSwiftPM graphを成立させるため `Generated/<Target>` をcommit対象化。

### G8 — End-to-end baseline proof

**Artifact:** acceptance evidence and executable

**Depends on:** G1–G7

**Status:** Verified on the current schema-4 tree

- real Mojo `1.0.0 (ed45d567)` compile。
- Xcode build + plugin + macro + static link。
- `add(20, 22) == 42`。
- final Mach-Oに4つのfixed ABI symbols。
- Mojo dylib dependencyなし。
- real external Mojo package import、prepare、release、static execution。
- arm64 `generic` とx86_64 `x86-64` objectを1つのtarget-scoped universal static frameworkへ統合。
- release packageから別directoryへ移設したclean consumerがMojo compilerなしでbuild/link/runし `42`。
- final consumer Mach-Oにtarget-scoped ABI symbolsが4つ存在し、Mojo dylib dependencyなし。
- 68 testsのfull package suiteとfocused unit/integration suiteをbounded `xcodebuild test` で各3回実行。

### G9 — Correctness and developer-experience hardening

**Artifact:** checked semantics、generation identity、incremental leaf tracking、interprocess transaction、bounded process owner、real-Mojo acceptance test

**Depends on:** G1–G8

**Status:** Verified

- checked `Int32` overflowとconditional compilation rejection。
- generation component versionsを合成したpipeline digestでcacheとverifyをinvalidate。
- XCFramework内部のfile overwriteとdirectory entry変更をbuild graphへ反映。
- cache readからcommitまでをinterprocess lockで直列化。
- compiler/build subprocessをprocess group単位でtimeout、terminate、kill、reap。
- normal suite内のcommitted schema-4 integration targetがplugin、macro、static link、`42`をcompiler-freeに毎回検証。
- `scripts/release-acceptance.sh` がreal Mojo external package、2-slice packaging、release gate、relocation、static symbols、no-dylib、`42`を独立して検証。

通常suite、artifact mutation、concurrent output access、bounded process ownership、real Mojo release acceptanceを実行済みです。nested fresh consumer内でSwiftSyntaxを毎回cold compileしていた旧integration testは、製品経路ではなく依存再構築が100秒を超えたため廃止しました。現在は通常package graph内のintegration fixtureと独立release acceptanceへ責務を分離しています。

Historicalなcold Release buildはSwiftSyntaxのhost-side compileがボトルネックとなり、2回の120秒制限内には完了しませんでした。current bounded workflowではtest timeoutとrelease timeoutを分離し、fresh-scratch compiler-free Release buildが165秒で完了しました。correctness gateはpassですが、SwiftSyntax cold compileは引き続きdeveloper-experience上の計測・改善対象です。

## 4. Phase 2 — DSL expansion and diagnostics

**Estimate:** 3–6 weeks

**Depends on:** Phase 1

Candidate semantics:

- numeric literals and more arithmetic operators。
- immutable local bindings。
- comparison and explicit conditional expressions/statements。
- bounded loops with statically understood ownership。
- generated Mojo inspection command（implemented and executed）。
- Mojo compiler diagnosticからSwiftSyntax rangeへのsource map（line mapping implemented、real diagnostic acceptance pending）。

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

**Depends on:** Phase 1 ABI/artifact pipeline. It can progress in parallel with Phase 2 because external Mojo packages do not require inline DSL expansion.

**Status:** `([Float]) throws -> Float` borrowed-input vertical slice is verified across IR、macro、generated Mojo/C ABI、Registry、typed error、unit/artifact tests、real Mojo compile、compiler-free link/runtime、empty-input failure、and Mach-O inspection. Allocation/copy measurement and sanitizer evidence are pending, so the broader Phase remains in progress.

Deliverables:

- fixed-width scalar matrix。
- borrowed contiguous `Float` input（first slice real-runtime verified; allocation/copy and sanitizer gates pending）。
- generic borrowed/owned contiguous buffers。
- UTF-8 string views。
- versioned records。
- signature familyごとに、direct value returnまたは明示的なowned diagnostic error envelopeを設計。
- owner/lease/borrow APIsとexactly-once deallocation。

Verification:

- safe reference implementationとのdifferential tests。
- bounds、alignment、overflow、aliasing、deallocation failure tests。
- allocation/copy countとperformance budget。
- Address Sanitizer等、対象環境で利用できるsanitizer。

First-slice convergence gate:

```mermaid
flowchart LR
    S["[Float] Swift API"] --> M["macro + Registry"]
    M --> C["const float* + count<br/>direct Float32 return"]
    C --> J["Mojo external function"]
    J --> R["runtime 10.0"]
    R --> E{"empty/error and<br/>lifetime gates pass?"}
    E -->|No| S
    E -->|Yes| V["Mark slice Verified"]
```

The functional slice is runtime-verified: real-Mojo release acceptance ran, the compiler-free relocated consumer executed scalar and buffer calls, and empty input returned the typed error. A zero-copy claim remains blocked until copy/allocation counts are measured rather than inferred, and the unsafe boundary still requires sanitizer evidence.

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

**Status:** scalar bridge、real external package、arm64/x86_64 universal packaging、build/release verification、compiler-free clean consumer、immutable remote revisionからのtwo-target link/runtimeはverified。remote binary distribution、model inferenceはpending

Deliverables:

- `SwiftMojo.json` にcompiler pin、Mojo packages、全required slicesを宣言（implemented）。
- `Mojo/<Package>/__init__.mojo` と全moduleを同じinput graphへ統合（implemented）。
- generated ABI entry moduleからMojo packageをimportし、declared bindingsをexport（implemented for scalar and borrowed `Float` signatures）。
- model-specific Swift APIとMojo sourceとartifactを結ぶcompatibility manifest。
- multiple Mojo-enabled targets向けtarget-derived static framework/module/archive/C symbol identityとtwo-target acceptance workflow（verified）。
- arm64/x86_64 Apple slice-aware schema-4 manifest、universal archive、XCFramework metadata gate（verified）。
- Apple XCFramework adapterと、SwiftPMの実在するlink capabilityに基づく非Apple artifact adapterの分離。
- release/cache identity including target accelerator（implemented; arbitrary target feature setはplanned）。
- remote artifact bundle or package distribution workflow。
- signed/reproducible generated artifact policy。
- SwiftPM Command Plugin、doctor/inspect、text/JSON output、compiler version diagnostics（implemented）。
- read-only release gate for config/source/package/source-map/slice/interface/artifact/local-dependency consistency（implemented）。
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
    P1["P1 proven"] --> P2["DSL semantics"]
    P1 --> P3["Ownership ABI"]
    P3 --> P4["Async/callback"] --> P6["GPU"]
    P3 --> P5["Model packages + distribution"] --> P6
    P2 --> Decision["Full inline syntax demand proof"] --> P7["Integration decision"]
```

主critical pathは `ownership ABI -> model package distribution -> GPU-capable model runtime` です。external Mojo packageを主surfaceにする限り、DSL expansionはownership ABIの前提ではなく並行laneです。最大のbottleneckは構文生成ではなく、ownership/error/device semanticsと、model packageでの実推論・remote distributionです。scalar compiler-free consumer artifactは実証済みで、borrowed `Float` sliceは最初の実装済みproof targetです。async/callbackとdistributionはownership ABIが安定した後に並行化できます。GPU Phaseは両方の成果を統合します。arbitrary inline syntax integrationは需要の立証前にcritical pathへ入れません。
