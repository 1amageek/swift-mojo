# ADR-0001: Offline prepare and verified static artifacts

- Status: Accepted for the static pipeline; artifact details superseded by ADR-0003
- Date: 2026-08-20
- Scope: P1 arm64 macOS pipeline

## Context

`@mojo func ... { return ... }` を通常のSwift functionとして使うには、次を同時に満たす必要があります。

- macroとMojo generatorが同じbody semanticsを使う。
- Mojo compiler outputがSwift linkへ参加する。
- Xcode/SwiftPM sandbox内でtoolchain installや不透明なruntime lookupを行わない。
- source変更後に古いartifactを使わない。
- final executableをbuild directory外へ移しても動く。
- SwiftPMがpackage graphを読む時点でbinary target pathが存在する。

初期prototypeはexternal symbolとdynamic shared libraryを使いました。しかし、public functionをthrowing loader callへ変え、absolute artifact path、runtime symbol resolution、library owner lifetimeを持ち込み、最終inline APIと責務が一致しませんでした。

## Decision

P1は次の二段階pipelineを採用します。

```text
Explicit preparation
  Swift source -> shared IR -> Mojo object -> static XCFramework + manifest

Normal build
  required inputs -> verifier -> generated Swift Registry -> static link
```

詳細:

1. Mojo compileはpublic author command `swift package --allow-writing-to-package-directory mojo prepare` だけが行う。
2. `MojoBuildPlugin` は `swift-mojo verify` だけを行う。
3. macro、prepare、verifyは同じ `MojoBindingCore` を使う。
4. C interfaceはfunctionごとのsymbolではなくfixed dispatcherを使う。
5. schema 3 manifestはsource/binding/compiler/target/ABI、generation pipeline identity、XCFramework tree digestを保持する。
6. `Generated/<Target>` はSwiftPM graph inputとしてcommitする。
7. `swift package --allow-writing-to-package-directory mojo init` はbinary targetをmanifestへ追加する前のbootstrapを作る。
8. runtime path lookupとdynamic loaderはP1から除去する。
9. prepare/initはoutput path単位のinterprocess lockをcache checkからcommitまで保持する。
10. compiler subprocessは専用process group、deadline、TERM/KILL escalation、reapを1つのownerが担う。
11. pluginはXCFramework rootだけでなく全descendant regular file/directoryをinputとして宣言する。

## Consequences

### Positive

- Swift public functionはnonthrowing direct callとして表現できる。
- runtimeにabsolute path、`dlopen`、rpath、symbol castがない。
- final executableは移設可能で、Mojo dylib installへ依存しない。
- build sandbox内にMojo compilerを要求しない。
- generated artifactの変更をsource reviewへ含められる。
- stale、missing、wrong-target、generation mismatch、corrupt artifactをcompile前に拒否できる。
- heavy prepare cacheとlight build verificationを分離できる。

### Negative

- developerはimplementation変更後に明示 `prepare` が必要。
- generated binary artifactをrepositoryへcommitする必要がある。
- schema-3 baselineはfixed generated module名のため1 package/1 Mojo target。
- schema-3 baselineのXCFrameworkはarm64 macOS sliceだけで、generic universal archiveは失敗する。
- compiler CLIのinstallation/distributionは別途必要。
- source-built executableはSwiftPM prebuild commandに使えないため、verifyは通常build commandである。

## Alternatives considered

### Compile Mojo inside the build plugin

Rejected for P1. Toolchain discovery、sandbox permissions、build latency、Xcode/CLI reproducibility、network-free behaviorを同時に悪化させます。pluginはprepared artifactの検証に限定します。

### Dynamic shared library and `dlopen`

Rejected for P1. Relocation、rpath、typed loader failure、function pointer、library lifetimeが通常callへ漏れます。hot-reloadなどdynamic loading自体が要件になった場合は、静的defaultと競合しない別backendとして再設計します。

### Macro directly invokes Mojo compiler

Rejected. Macroはdeterministic source transformationであり、file/process I/Oのownerにしません。Swift compile中のside effectとbuild graph追跡も不適切です。

### Prebuild command always verifies

Rejected by demonstrated SwiftPM constraint: prebuild command cannot use an executable target built from source.通常build commandでmanifest、XCFramework root、全descendant regular file/directoryをrequired inputsにすることで、missing inputとincremental correctnessを維持します。

### Only hash the static archive

Rejected after review. C header、module map、XCFramework metadataもcompile/link semanticsの一部です。schema 3ではcanonical tree全体をhashし、各leafとdirectoryをbuild inputとして追跡します。

### Ignore generated artifacts

Rejected. SwiftPM local binary targetはpackage graph読込時にpathを必要とし、plugin実行前のためfresh cloneが解決不能になります。

## Invariants introduced

1. prepare以外はpackage-owned artifactを書き換えない。
2. versioned markerが一致しないdirectoryを置換しない。
3. current sourceとmanifestが一致しないbuildは成功しない。
4. XCFramework interfaceとarchiveを同じdigest envelopeで検証する。
5. fixed dispatcherはRegistry membership check後だけ呼ぶ。
6. generated artifactが必要なtargetはそれをexplicit binary dependencyに持つ。
7. generator/lowering/packaging/Registry rendererの変更はgeneration pipeline identityを更新し、古いartifactを再利用しない。
8. output transactionはtyped exclusive-access leaseなしにcommitできない。
9. P1の `Int32 +` はchecked arithmeticであり、overflow時にMojo dispatcherを呼ばない。
10. active build conditionをsource graphへ供給できない間、`@mojo` declarationをconditional compilation内で受理しない。

## Revisit triggers

- SwiftPMがplugin-generated link inputsまたはartifact bundlesをpackage graph前に扱える。
- multiple targets/platform slicesがP1 fixed module conventionを越える。
- binary artifact repository sizeがdistribution要件を満たさない。
- dynamic loading自体が明示要件になる。
- Mojo runtime-dependent featuresがstatic initialization ABIを必要とする。
