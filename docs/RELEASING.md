# Release process

No semantic-version release has been tagged yet. `main` remains a development dependency and `SwiftMojoVersion.current` remains a `-dev` version until every gate below has evidence from the same commit.

## Release invariants

```mermaid
flowchart LR
    V["Set exact version"] --> S["Source and package gates"]
    S --> T["Bounded tests"]
    T --> P["Commit and push candidate"]
    P --> A["Immutable-revision Mojo acceptance"]
    A --> M["Two-target + cold build evidence"]
    M --> F["Candidate version/release gate"]
    F --> G["Create and push tag"]
    G --> E["Exact-version resolution<br/>and tag == origin/main"]
```

| Gate | Required evidence |
|---|---|
| Dependency graph | Root `Package.swift` has no `.package(path:)` or other local package dependency |
| Public surface | `swift package --allow-writing-to-package-directory mojo ...` is the documented author command; the internal executable is not a product |
| Version | `SwiftMojoVersion.current` is exactly the release version and has no `-dev` suffix |
| Generated state | bindings、Mojo source、source map、manifest、header、XCFramework、and pipeline identity agree |
| Tests | Focused suites and the complete package suite pass through bounded `xcodebuild test` |
| Real compiler | Updated `scripts/release-acceptance.sh` compiles and runs scalar and borrowed-buffer paths |
| Multiple targets | `scripts/multi-target-acceptance.sh` links two Mojo-enabled targets with two symbol prefixes |
| Consumer DX | `scripts/measure-cold-consumer-build.sh` records a bounded fresh-scratch Release build with Mojo absent |
| Git state | Candidate is committed, pushed, and `origin/main` points to the candidate |
| Tag | Annotated semantic-version tag points to exactly `origin/main` |

## Candidate procedure

1. Choose the semantic version and replace the development version in `Sources/MojoCommandCore/SwiftMojoVersion.swift`.
2. Replace branch-based dependency examples with the intended semantic-version requirement only when that tag will be created in the same release operation.
3. Confirm the root manifest contains no local package reference.
4. Run the focused and full test matrices with explicit timeouts.
5. Commit and push the candidate revision, then run the public command-plugin acceptance against that immutable revision:

   ```bash
   SWIFT_MOJO_EXECUTABLE=/absolute/path/to/mojo \
   SWIFT_MOJO_CANDIDATE_URL=https://github.com/owner/swift-mojo.git \
   scripts/release-acceptance.sh

   SWIFT_MOJO_EXECUTABLE=/absolute/path/to/mojo \
   SWIFT_MOJO_CANDIDATE_URL=https://github.com/owner/swift-mojo.git \
   scripts/multi-target-acceptance.sh
   ```

6. Retain the cold Release timing printed by `release-acceptance.sh`. It invokes `measure-cold-consumer-build.sh` with a new scratch directory and Mojo absent. Run the measurement script separately only when diagnosing or comparing consumer build performance.
7. Review `git diff`, generated artifact changes, ADR status, and every `FIXME(INCOMPLETE_IMPLEMENTATION)` marker. The intentional bootstrap marker must remain unreachable as a prepared artifact.
8. If acceptance requires a fix, create and push a new candidate commit and repeat the invalidated gates. Do not reuse evidence from the previous revision.
9. Fetch `origin`, then run the final version/tag preflight. It builds and invokes the public command plugin from the candidate source in an isolated scratch directory:

   ```bash
   scripts/release-version-gate.sh <version> <tag>
   ```

10. Create and push the annotated tag.
11. Prove that a fresh package resolves the public command plugin through the exact semantic version rather than a local path、branch、or revision override:

    ```bash
    SWIFT_MOJO_CANDIDATE_URL=https://github.com/owner/swift-mojo.git \
    scripts/release-tag-gate.sh <version> <tag>
    ```

12. The tag gate also verifies the following equality explicitly:

    ```bash
    git rev-list -1 <tag>
    git rev-parse origin/main
    ```

    The two object IDs must match.

## Failure policy

A timeout, skipped architecture, compiler fallback, stale generated file, dirty candidate, local dependency, or unexecuted acceptance gate is not a release pass. Fix the cause, create a new candidate commit, and rerun only the invalidated gates plus all downstream gates. Do not move an already published release tag.
