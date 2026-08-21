# Cold consumer build benchmark

This benchmark measures a fresh-scratch Release build of an existing compiler-free consumer package. It is intentionally separate from `Tests/`, release acceptance, and normal CI because elapsed build time is an environment-sensitive developer-experience measurement rather than a correctness assertion.

Run it explicitly with an absolute path to a consumer whose prepared Mojo artifact is already present:

```bash
Benchmarks/ColdConsumerBuild/run.sh \
    /absolute/path/to/compiler-free-consumer-package
```

The harness removes Mojo from `PATH`, creates a new temporary scratch directory for every run, applies a bounded timeout, and reports elapsed whole seconds. The caller should retain the commit, host, Xcode, Swift toolchain, dependency-cache state, and output when comparing measurements.
