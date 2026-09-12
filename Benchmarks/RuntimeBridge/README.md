# Runtime bridge benchmark

This benchmark is intentionally separate from `Tests/` and the normal CI workflow. It prepares a temporary Mojo-backed consumer, builds one Release executable, and measures these two paths against the same generated dispatcher:

1. the public `@mojo` Swift wrapper;
2. a direct generated C dispatcher call with the same scoped Span borrow.

The harness reports p50 and p95 nanoseconds per call, the wrapper/direct ratio, buffer size, warm-up count, sample count, calls per sample, host OS, Swift version, and Mojo version. It does not enforce a latency threshold. Performance acceptance requires reviewing the recorded environment and repeated measurements rather than turning wall-clock noise into a unit-test failure.

Run it explicitly from the repository root:

```bash
SWIFT_MOJO_EXECUTABLE=/absolute/path/to/mojo \
Benchmarks/RuntimeBridge/run.sh
```

Optional positional arguments select buffer element count, sample count, and calls per sample:

```bash
SWIFT_MOJO_EXECUTABLE=/absolute/path/to/mojo \
Benchmarks/RuntimeBridge/run.sh 4096 80 100
```

The script uses a temporary directory and removes it on exit. It does not write benchmark products into the repository.

## Native session boundary

`run-session.py` uses the checked-in integration fixture, the real macro plugin,
and a verified generated registry. Build the package tooling first, then run:

```sh
swift build --product swift-mojo
swift build --target MojoMacros
python3 Benchmarks/RuntimeBridge/run-session.py
python3 Benchmarks/RuntimeBridge/run-session.py --allocations
```

Each compiler, verifier and executable command has a 120-second timeout.
`--products` selects the native SwiftPM products directory and `--swiftc` selects
the compiler. The runner supports the prepared macOS and aarch64 Linux slices.
Jetson qualification compiled the same sources with its native macro plugin
inside the existing isolated Ubuntu build root, then ran the ELF executables
on WendyOS 0.19.1; it did not emulate Linux on the Mac.

The public path includes preflight lookup, disjoint-buffer validation and one
exclusive session admission per invocation. The direct baseline retains one
valid session borrow outside the timed loop and calls the exact same linked
Mojo dispatcher. Buffers are allocated and initialized before measurement, order
alternates, and every output element is checked outside each timed sample.
The workload is CPU Float32 doubling, not MAX inference or GPU execution.

[Recorded timings](results/2026-09-12-session.csv) and
[environment and limits](results/2026-09-12-session.json) cover 1 through
1,048,576 elements on Mac and Jetson. Differences near zero can be negative
because they subtract independently measured medians.

Allocation interception is a separate run, never used for latency numbers.
The test-only C interposer is not linked into library products. It observes
`malloc`, `calloc`, `realloc`, `posix_memalign`, and the listed Darwin zone
allocation entry points. A real Swift allocation must be detected before the
measurement is accepted. On both hosts it detected that control and counted
zero allocator entry calls in each 1,000-call public invocation loop at 1,
4,096 and 1,048,576 elements. This is evidence for the warmed synchronous CPU
fixture; it does not count arbitrary device allocation or prove another authored
Mojo operation's behavior. Span forwards the existing host pointer, while an
Array caller may still incur COW before entering the binding.


## Opaque resource boundary

`run-session.py --resources` executes public macro-to-Mojo acceptance before a
2/3/8/32/128-resource size sweep. The baseline uses the identical C ABI symbol
while holding one resource lease outside the timed loop. Numeric checks run after
each sample. Use `--resources --allocations` for separate host allocator interception,
or `--resources --sanitize-address` to instrument the Swift ownership boundary.

[Recorded timings](results/2026-09-13-resources.csv) and
[provenance, allocation observations and limits](results/2026-09-13-resources.json)
cover Mac and native Jetson. On the final Swift 6.4 snapshot, a two-resource public
call measured 61.541 ns on Mac and 160.452 ns on Jetson (median). The corresponding
additional cost over the direct dispatcher was 58.749 ns and 154.756 ns. All five
sizes observed zero intercepted allocator calls over 1,000 warmed invocations on
both hosts, with positive interception controls. This is CPU boundary evidence;
it does not measure GPU work, MAX inference or camera-to-display latency.
