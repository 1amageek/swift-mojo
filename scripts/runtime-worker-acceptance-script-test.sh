#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly ACCEPTANCE_SCRIPT="$SCRIPT_DIR/runtime-worker-acceptance.sh"
readonly COMMAND_TIMEOUT="$SCRIPT_DIR/command-timeout.sh"
test_root_candidate="$(
    mktemp -d "${TMPDIR:-/tmp}/swift-mojo-rt4b-script-test.XXXXXX"
)"
readonly TEST_ROOT="$(cd "$test_root_candidate" && pwd)"
unset test_root_candidate
readonly EXPECTED_REVISION="$(
    /usr/bin/git -C "$REPOSITORY_ROOT" rev-parse --verify 'HEAD^{commit}'
)"

test_cleanup() {
    local line=""
    local process_id=""
    local process_group_id=""
    local group_ids=""
    if [[ -d "$TEST_ROOT" ]]; then
        while IFS= read -r line; do
            [[ "$line" == *"$TEST_ROOT/"*"/swift-mojo-worker-"* ]] || continue
            read -r process_id process_group_id _ <<< "$line"
            [[ "$process_group_id" =~ ^[1-9][0-9]*$ ]] || continue
            case " $group_ids " in
                *" $process_group_id "*) ;;
                *) group_ids+=" $process_group_id" ;;
            esac
        done < <(/bin/ps -axo pid=,pgid=,command=)
        for process_group_id in $group_ids; do
            /bin/kill -KILL "-$process_group_id" 2>/dev/null || true
        done
        /usr/bin/find "$TEST_ROOT" -type d -exec /bin/chmod u+w {} + \
            2>/dev/null || true
        /bin/rm -rf -- "$TEST_ROOT"
    fi
}
trap test_cleanup EXIT

if [[ ! "$EXPECTED_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    echo "test repository HEAD is not a lowercase Git object ID" >&2
    exit 1
fi

fake_bin="$TEST_ROOT/bin"
fake_rm_bin="$TEST_ROOT/rm-bin"
fake_modular_home="$TEST_ROOT/modular"
fake_build_bin="$TEST_ROOT/build-bin"
mkdir -p \
    "$fake_bin" \
    "$fake_rm_bin" \
    "$fake_modular_home/lib" \
    "$fake_build_bin"

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
echo "unexpected direct mojo invocation: $*" >&2
exit 1
EOF

cat > "$fake_bin/swift" <<'EOF'
#!/bin/sh
set -eu

product=''
package_path=''
show_bin_path=0
previous=''
for argument in "$@"; do
    if [ "$previous" = '--product' ]; then
        product="$argument"
    elif [ "$previous" = '--package-path' ]; then
        package_path="$argument"
    fi
    if [ "$argument" = '--show-bin-path' ]; then
        show_bin_path=1
    fi
    previous="$argument"
done

phase='bootstrap'
case "$package_path" in
    */acceptance-source/*|*/production/swift-mojo)
        phase='verified-source-v1'
        ;;
esac
repository_root="${SWIFT_MOJO_REPOSITORY_ROOT:-}"
printf 'fake-swift phase=%s product=%s package=%s repository=%s\n' \
    "$phase" "$product" "$package_path" "$repository_root" >&2

if [ "$phase" = 'verified-source-v1' ]; then
    case "$package_path" in
        */acceptance-source/Acceptance/RuntimeWorker)
            verified_source_root="${package_path%/Acceptance/RuntimeWorker}"
            test -f "$verified_source_root/.verified-source-snapshot"
            case "$repository_root" in
                */production/swift-mojo) ;;
                *) echo 'source package dependency root is not the production archive' >&2; exit 1 ;;
            esac
            ;;
        */acceptance-source/Acceptance/RuntimeWorker/Fixtures/Consumer)
            verified_source_root="${package_path%/Acceptance/RuntimeWorker/Fixtures/Consumer}"
            test -f "$verified_source_root/.verified-source-snapshot"
            case "$repository_root" in
                */production/swift-mojo) ;;
                *) echo 'source package dependency root is not the production archive' >&2; exit 1 ;;
            esac
            ;;
        */production/swift-mojo)
            test -f "$package_path/Package.swift"
            ;;
        *)
            echo "verified phase received an unverified package path: $package_path" >&2
            exit 1
            ;;
    esac
fi

if [ "${1:-}" = 'build' ] && [ "$product" != '' ]; then
    executable="$FAKE_BUILD_BIN/$product"
    case "$product" in
        swift-mojo)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
set -eu
if [ "${1:-}" = 'runtime-worker-prepare' ]; then
    package_root=''
    source_root=''
    source=''
    output=''
    previous=''
    for argument in "$@"; do
        case "$previous" in
            --package-root) package_root="$argument" ;;
            --source-root) source_root="$argument" ;;
            --source) source="$argument" ;;
            --output) output="$argument" ;;
        esac
        previous="$argument"
    done
    verified_source_root="${package_root%/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel}"
    printf 'fake-authoring package=%s source-root=%s source=%s repository=%s\n' \
        "$package_root" "$source_root" "$source" \
        "${SWIFT_MOJO_REPOSITORY_ROOT:-}" >&2
    case "$package_root" in
        "$verified_source_root"/*) ;;
        *) echo 'model package did not come from verified source snapshot' >&2; exit 1 ;;
    esac
    case "$source_root" in
        "$verified_source_root"/*) ;;
        *) echo 'model source root did not come from verified source snapshot' >&2; exit 1 ;;
    esac
    case "$source" in
        "$verified_source_root"/*) ;;
        *) echo 'binding source did not come from verified source snapshot' >&2; exit 1 ;;
    esac
    case "${SWIFT_MOJO_REPOSITORY_ROOT:-}" in
        */production/swift-mojo) ;;
        *) echo 'authoring dependency root did not come from production archive' >&2; exit 1 ;;
    esac
    /bin/mkdir -p "$output"
    : > "$output/manifest.json"
    exit 0
fi
if [ "${1:-}" = 'runtime-worker-verify' ]; then
    printf '%s\n' 'fake-runtime-worker-verify=passed' >&2
    exit 0
fi
echo "unexpected fake swift-mojo invocation: $*" >&2
exit 1
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
set -eu

if [ "${1:-}" = '--execute-verified-source-at' ]; then
    source_root="$2"
    if [ "${3:-}" != '--destination' ] \
        || [ "${5:-}" != '--live-git-root' ] \
        || [ "${7:-}" != '--' ]; then
        echo 'verified source execution arguments are incomplete' >&2
        exit 1
    fi
    destination="$4"
    live_git_root="$6"
    /bin/mkdir -p \
        "$destination/scripts" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/Consumer" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel"
    /bin/cp "$source_root/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/runtime-worker-acceptance.sh"
    /bin/cp "$source_root/scripts/command-timeout.sh" \
        "$destination/scripts/command-timeout.sh"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Fixtures/Consumer/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/Consumer/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Package.swift"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    : > "$destination/.verified-source-snapshot"
    /usr/bin/find "$destination" -type f -exec /bin/chmod 0444 {} +
    /bin/chmod 0555 \
        "$destination/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/command-timeout.sh"
    /usr/bin/find "$destination" -type d -exec /bin/chmod 0555 {} +
    printf 'fake-snapshot-source=%s\n' "$source_root" >&2
    printf 'fake-snapshot-destination=%s\n' "$destination" >&2
    shift 7
    script_contents="$(/bin/cat "$destination/scripts/runtime-worker-acceptance.sh")"
    exec /bin/bash -c "$script_contents" \
        swift-mojo-runtime-worker-acceptance-verified-v1 \
        "$destination" \
        "$live_git_root" \
        "$(printf '%064d' 0)" \
        "$@"
fi

if [ "${1:-}" = '--snapshot-source-at' ]; then
    source_root="$2"
    if [ "${3:-}" != '--destination' ]; then
        echo 'snapshot destination argument is missing' >&2
        exit 1
    fi
    destination="$4"
    /bin/mkdir -p \
        "$destination/scripts" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/Consumer" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel"
    /bin/cp "$source_root/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/runtime-worker-acceptance.sh"
    /bin/cp "$source_root/scripts/command-timeout.sh" \
        "$destination/scripts/command-timeout.sh"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Fixtures/Consumer/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/Consumer/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Package.swift"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    : > "$destination/.verified-source-snapshot"
    /usr/bin/find "$destination" -type f -exec /bin/chmod 0444 {} +
    /bin/chmod 0555 \
        "$destination/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/command-timeout.sh"
    /usr/bin/find "$destination" -type d -exec /bin/chmod 0555 {} +
    printf 'fake-snapshot-source=%s\n' "$source_root" >&2
    printf 'fake-snapshot-destination=%s\n' "$destination" >&2
    printf '%064d\n' 0
    exit 0
fi

if [ "${1:-}" = '--source-digest-at' ]; then
    printf 'fake-source-digest-root=%s\n' "${2:-}" >&2
    if [ "${FAKE_SOURCE_DIGEST_MISMATCH:-0}" = '1' ]; then
        printf '%064d\n' 1
    else
        printf '%064d\n' 0
    fi
    exit 0
fi

repository_root=''
expected_digest=''
revision=''
tmpdir=''
previous=''
for argument in "$@"; do
    case "$previous" in
        --repository-root) repository_root="$argument" ;;
        --expected-source-digest) expected_digest="$argument" ;;
        --swift-mojo-revision) revision="$argument" ;;
        --tmpdir) tmpdir="$argument" ;;
    esac
    previous="$argument"
done
printf 'fake-controller repository=%s digest=%s revision=%s tmpdir=%s\n' \
    "$repository_root" "$expected_digest" "$revision" "$tmpdir" >&2

mode="$(/bin/cat "$0.mode")"
if [ "$mode" = 'leak' ]; then
    stage="$TMPDIR/swift-mojo-worker-shell-test"
    /bin/mkdir -p "$stage"
    printf '%s\n' '#!/bin/sh' 'while :; do /bin/sleep 1; done' > "$stage/sleeper.sh"
    /bin/chmod +x "$stage/sleeper.sh"
    /usr/bin/perl -MPOSIX -e \
        "POSIX::setsid() or die \$!; exec '/bin/sh', \$ARGV[0] or die \$!;" \
        "$stage/sleeper.sh" >/dev/null 2>&1 &
    /bin/sleep 1
fi
exit 0
SCRIPT
            printf '%s\n' "${FAKE_CONTROLLER_MODE:-clean}" > "$executable.mode"
            ;;
        *)
            echo "unexpected product: $product" >&2
            exit 1
            ;;
    esac
    /bin/chmod +x "$executable"
fi

if [ "$show_bin_path" -eq 1 ]; then
    printf '%s\n' "$FAKE_BUILD_BIN"
fi
exit 0
EOF

cat > "$fake_rm_bin/rm" <<'EOF'
#!/bin/sh
set -eu
fail_cleanup=0
for argument in "$@"; do
    if [ "$argument" = '-rf' ] || [ "$argument" = '-fr' ]; then
        fail_cleanup=1
    fi
done
if [ "$fail_cleanup" -eq 1 ]; then
    for argument in "$@"; do
        case "$argument" in
            */swift-mojo-rt4b.*) exit 91 ;;
        esac
    done
fi
exec /bin/rm "$@"
EOF

/bin/chmod +x "$fake_bin/mojo" "$fake_bin/swift" "$fake_rm_bin/rm"

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

assert_no_acceptance_temp() {
    local case_tmpdir="$1"
    local remaining_path=""
    for remaining_path in "$case_tmpdir"/swift-mojo-rt4b.*; do
        if [[ -e "$remaining_path" || -L "$remaining_path" ]]; then
            echo "acceptance temporary path survived cleanup: $remaining_path" >&2
            exit 1
        fi
    done
}

run_acceptance() {
    local case_tmpdir="$1"
    local case_path="$2"
    local output_path="$3"
    local source_digest_mismatch="${4:-0}"
    local controller_mode="${5:-clean}"
    mkdir -p "$case_tmpdir"
    "$COMMAND_TIMEOUT" 40 -- /usr/bin/env \
        "MODULAR_HOME=$fake_modular_home" \
        "SWIFT_MOJO_EXECUTABLE=$fake_bin/mojo" \
        "FAKE_BUILD_BIN=$fake_build_bin" \
        "FAKE_SOURCE_DIGEST_MISMATCH=$source_digest_mismatch" \
        "FAKE_CONTROLLER_MODE=$controller_mode" \
        "TMPDIR=$case_tmpdir" \
        "PATH=$case_path" \
        "RT4_TIMEOUT_SECONDS=5" \
        "RT4_ACCEPTANCE_PHASE=verified-source-v1" \
        "RT4_VERIFIED_SOURCE_ROOT=$case_tmpdir/forged-source" \
        "RT4_LIVE_GIT_REPOSITORY_ROOT=$case_tmpdir/forged-git" \
        "RT4_ACCEPTANCE_SOURCE_DIGEST=$(printf '%064d' 9)" \
        "RT4_WORK_DIR=$case_tmpdir/forged-work" \
        "$ACCEPTANCE_SCRIPT" \
        --target-triple test-apple-macosx-target \
        --target-cpu test-cpu \
        --target-accelerator test-accelerator \
        --runtime-library "$fake_modular_home/lib/libAsyncRTRuntimeGlobals.dylib" \
        > "$output_path" 2>&1
}

assert_verified_inputs() {
    local output_path="$1"
    local case_tmpdir="$2"
    local snapshot_prefix="$case_tmpdir/swift-mojo-rt4b."
    local actual_snapshot_root=""
    actual_snapshot_root="$(
        /usr/bin/sed -n 's/^fake-snapshot-destination=//p' "$output_path" | \
            /usr/bin/tail -n 1
    )"
    if [[ "$actual_snapshot_root" != "$snapshot_prefix"*"/acceptance-source" ]]; then
        echo "verified source snapshot was not placed under the private work directory" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    local work_dir="${actual_snapshot_root%/acceptance-source}"
    local production_root="$work_dir/production/swift-mojo"
    local acceptance_root="$actual_snapshot_root/Acceptance/RuntimeWorker"
    local consumer_root="$acceptance_root/Fixtures/Consumer"
    local model_root="$acceptance_root/Fixtures/RuntimeWorkerAcceptanceModel"
    local bindings_source="$model_root/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    local expected_digest="$(printf '%064d' 0)"

    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product=runtime-worker-acceptance package=$acceptance_root repository=$production_root" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product=swift-mojo package=$production_root repository=" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product=RuntimeWorkerAcceptanceConsumer package=$consumer_root repository=$production_root" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-authoring package=$model_root source-root=$model_root source=$bindings_source repository=$production_root" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-source-digest-root=$actual_snapshot_root" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-controller repository=$actual_snapshot_root digest=$expected_digest revision=$EXPECTED_REVISION" \
        "$output_path"
    if /usr/bin/grep -F 'phase=verified-source-v1' "$output_path" | \
        /usr/bin/grep -Fq "package=$REPOSITORY_ROOT"; then
        echo "verified phase read a live-repository package path" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
}

verified_tmpdir="$TEST_ROOT/verified-tmp"
verified_output="$TEST_ROOT/verified-output.log"
set +e
run_acceptance \
    "$verified_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$verified_output"
exit_status=$?
set -e
if ((exit_status != 0)); then
    echo "expected verified-source execution to exit 0, got $exit_status" >&2
    /bin/cat "$verified_output" >&2
    exit 1
fi
assert_verified_inputs "$verified_output" "$verified_tmpdir"
assert_no_worker_process "$verified_tmpdir"
assert_no_acceptance_temp "$verified_tmpdir"

source_mismatch_tmpdir="$TEST_ROOT/source-mismatch-tmp"
source_mismatch_output="$TEST_ROOT/source-mismatch-output.log"

set +e
run_acceptance \
    "$source_mismatch_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$source_mismatch_output" \
    1
exit_status=$?
set -e

if ((exit_status != 1)); then
    echo "expected source mismatch to exit 1, got $exit_status" >&2
    /bin/cat "$source_mismatch_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q \
    'execution runner does not match the verified source snapshot' \
    "$source_mismatch_output"; then
    echo 'source mismatch was not reported' >&2
    /bin/cat "$source_mismatch_output" >&2
    exit 1
fi
assert_no_worker_process "$source_mismatch_tmpdir"
assert_no_acceptance_temp "$source_mismatch_tmpdir"

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
/usr/bin/find "$rm_failure_tmpdir" -type d -exec /bin/chmod u+w {} +
/bin/rm -rf -- "$rm_failure_tmpdir"

leak_tmpdir="$TEST_ROOT/leak-tmp"
leak_output="$TEST_ROOT/leak-output.log"

set +e
run_acceptance \
    "$leak_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$leak_output" \
    0 \
    leak
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
assert_no_acceptance_temp "$leak_tmpdir"

echo 'runtime-worker-acceptance verified-source, failure, and cleanup paths passed'
