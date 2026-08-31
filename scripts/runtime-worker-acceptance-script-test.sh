#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ACCEPTANCE_SCRIPT="$SCRIPT_DIR/runtime-worker-acceptance.sh"
readonly TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-mojo-rt4b-script-test.XXXXXX")"
trap '/bin/rm -rf -- "$TEST_ROOT"' EXIT

fake_bin="$TEST_ROOT/bin"
fake_rm_bin="$TEST_ROOT/rm-bin"
fake_modular_home="$TEST_ROOT/modular"
fake_build_bin="$TEST_ROOT/build-bin"
mkdir -p "$fake_bin" "$fake_rm_bin" "$fake_modular_home/lib" "$fake_build_bin"

for library in \
    libAsyncRTRuntimeGlobals.dylib \
    libKGENCompilerRTShared.dylib \
    libMSupportGlobals.dylib; do
    : > "$fake_modular_home/lib/$library"
done

cat > "$fake_bin/mojo" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'Mojo 1.0.0 (ed45d567)'
    exit 0
fi
if [ "${2:-}" = "runtime-worker-prepare" ]; then
    previous=''
    for argument in "$@"; do
        if [ "$previous" = '--output' ]; then
            mkdir -p "$argument"
            : > "$argument/manifest.json"
        fi
        previous="$argument"
    done
fi
exit 0
EOF

cat > "$fake_bin/swift" <<'EOF'
#!/bin/sh
product=''
previous=''
for argument in "$@"; do
    if [ "$previous" = '--product' ]; then
        product="$argument"
    fi
    previous="$argument"
done
if [ "${1:-}" = 'build' ] && [ "${product:-}" != '' ]; then
    executable="$FAKE_BUILD_BIN/$product"
    case "$product" in
        swift-mojo)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
if [ "${1:-}" = 'runtime-worker-prepare' ]; then
    previous=''
    for argument in "$@"; do
        if [ "$previous" = '--output' ]; then
            mkdir -p "$argument"
            : > "$argument/manifest.json"
        fi
        previous="$argument"
    done
fi
exit 0
SCRIPT
            ;;
        RuntimeWorkerAcceptanceConsumer)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
            ;;
        runtime-worker-acceptance)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
stage="$TMPDIR/swift-mojo-worker-shell-test"
/bin/mkdir -p "$stage"
printf '%s\n' '#!/bin/sh' 'while :; do /bin/sleep 1; done' > "$stage/sleeper.sh"
/bin/chmod +x "$stage/sleeper.sh"
/usr/bin/perl -MPOSIX -e "POSIX::setsid() or die \$!; exec '/bin/sh', \$ARGV[0] or die \$!;" "$stage/sleeper.sh" >/dev/null 2>&1 &
/bin/sleep 1
exit 0
SCRIPT
            ;;
    esac
    chmod +x "$executable"
fi
if printf '%s\n' "$@" | /usr/bin/grep -q -- '--show-bin-path'; then
    printf '%s\n' "$FAKE_BUILD_BIN"
fi
exit 0
EOF

cat > "$fake_rm_bin/rm" <<'EOF'
#!/bin/sh
exit 91
EOF

chmod +x "$fake_bin/mojo" "$fake_bin/swift" "$fake_rm_bin/rm"

assert_no_worker_process() {
    local case_tmpdir="$1"
    if /bin/ps -axo pid=,pgid=,command= | \
        /usr/bin/grep -F "$case_tmpdir/" | \
        /usr/bin/grep -F '/swift-mojo-worker-' >/dev/null; then
        echo "worker process survived shell cleanup for $case_tmpdir" >&2
        /bin/ps -axo pid=,pgid=,command= >&2
        exit 1
    fi
}

run_acceptance() {
    local case_tmpdir="$1"
    local case_path="$2"
    local output_path="$3"
    mkdir -p "$case_tmpdir"
    MODULAR_HOME="$fake_modular_home" \
    SWIFT_MOJO_EXECUTABLE="$fake_bin/mojo" \
    FAKE_BUILD_BIN="$fake_build_bin" \
    TMPDIR="$case_tmpdir" \
    PATH="$case_path" \
    RT4_TIMEOUT_SECONDS=5 \
        "$ACCEPTANCE_SCRIPT" \
        --target-triple test-apple-macosx-target \
        --target-cpu test-cpu \
        --target-accelerator test-accelerator \
        --runtime-library "$fake_modular_home/lib/libAsyncRTRuntimeGlobals.dylib" \
        > "$output_path" 2>&1
}

rm_failure_tmpdir="$TEST_ROOT/rm-failure-tmp"
rm_failure_output="$TEST_ROOT/rm-failure-output.log"

set +e
run_acceptance \
    "$rm_failure_tmpdir" \
    "$fake_rm_bin:$fake_bin:/usr/bin:/bin" \
    "$rm_failure_output"
exit_status=$?
set -e

if ((exit_status != 1)); then
    echo "expected cleanup failure to exit 1, got $exit_status" >&2
    /bin/cat "$rm_failure_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'acceptance work directory cleanup failed' \
    "$rm_failure_output"; then
    echo 'cleanup failure was not reported' >&2
    /bin/cat "$rm_failure_output" >&2
    exit 1
fi
assert_no_worker_process "$rm_failure_tmpdir"

leak_tmpdir="$TEST_ROOT/leak-tmp"
leak_output="$TEST_ROOT/leak-output.log"

set +e
run_acceptance \
    "$leak_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$leak_output"
exit_status=$?
set -e

if ((exit_status != 1)); then
    echo "expected recovered worker leak to exit 1, got $exit_status" >&2
    /bin/cat "$leak_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'acceptance cleanup observed leaked worker process group' \
    "$leak_output"; then
    echo 'worker process leak was not reported' >&2
    /bin/cat "$leak_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'acceptance cleanup observed leaked worker stage' \
    "$leak_output"; then
    echo 'worker stage leak was not reported' >&2
    /bin/cat "$leak_output" >&2
    exit 1
fi
assert_no_worker_process "$leak_tmpdir"

remaining_path=""
for remaining_path in "$leak_tmpdir"/swift-mojo-rt4b.*; do
    if [[ -e "$remaining_path" || -L "$remaining_path" ]]; then
        echo "acceptance temporary path survived cleanup: $remaining_path" >&2
        exit 1
    fi
done

echo 'runtime-worker-acceptance cleanup failure and recovered-leak paths passed'
