# Runtime bridge benchmark

This benchmark is intentionally separate from `Tests/` and the normal CI workflow. It prepares a temporary Mojo-backed consumer, builds one Release executable, and measures these two paths against the same generated dispatcher:

1. the public `@mojo` Swift wrapper;
2. a direct generated C dispatcher call with the same scoped array borrow.

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
