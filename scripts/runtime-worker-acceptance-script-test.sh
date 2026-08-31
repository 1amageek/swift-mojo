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
fake_slow_rm_bin="$TEST_ROOT/slow-rm-bin"
fake_modular_home="$TEST_ROOT/modular"
fake_build_bin="$TEST_ROOT/build-bin"
mkdir -p \
    "$fake_bin" \
    "$fake_rm_bin" \
    "$fake_slow_rm_bin" \
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
scratch_path=''
show_bin_path=0
plugin_command=''
binding_source=''
binding_source_count=0
raw_source_option=0
previous=''
for argument in "$@"; do
    if [ "$previous" = '--product' ]; then
        product="$argument"
    elif [ "$previous" = '--package-path' ]; then
        package_path="$argument"
    elif [ "$previous" = '--scratch-path' ]; then
        scratch_path="$argument"
    elif [ "$previous" = 'mojo' ]; then
        plugin_command="$argument"
    elif [ "$previous" = '--binding-source' ]; then
        binding_source="$argument"
        binding_source_count=$((binding_source_count + 1))
    fi
    if [ "$argument" = '--show-bin-path' ]; then
        show_bin_path=1
    fi
    if [ "$argument" = '--source' ] || [ "$argument" = '--source-root' ]; then
        raw_source_option=1
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
printf 'fake-swift phase=%s product=%s package=%s repository=%s scratch=%s\n' \
    "$phase" "$product" "$package_path" "$repository_root" \
    "$scratch_path" >&2
if [ -n "${FAKE_SWIFT_TRACE_PATH:-}" ]; then
    printf 'fake-swift phase=%s product=%s package=%s repository=%s scratch=%s\n' \
        "$phase" "$product" "$package_path" "$repository_root" \
        "$scratch_path" >> "$FAKE_SWIFT_TRACE_PATH"
fi

case "$product" in
    runtime-worker-acceptance-source)
        printf '%s\n' \
            'swiftc -frontend -c -module-name RuntimeWorkerAcceptanceSourceIdentity' \
            'swiftc -frontend -c -module-name RuntimeWorkerAcceptanceSourceRunner' >&2
        if [ "${FAKE_BOOTSTRAP_FORBIDDEN_MODULE:-0}" = '1' ]; then
            printf '%s\n' \
                'swiftc -frontend -c -module-name MojoRuntime' >&2
        fi
        ;;
    runtime-worker-acceptance)
        printf '%s\n' \
            'swiftc -frontend -c -module-name MojoRuntime' \
            'swiftc -frontend -c -module-name RuntimeWorkerAcceptance' \
            'swiftc -frontend -c -module-name RuntimeWorkerAcceptanceRunner' >&2
        ;;
    RuntimeWorkerAcceptanceConsumer)
        printf '%s\n' \
            'swiftc -frontend -c -module-name RuntimeWorkerAcceptanceConsumer' >&2
        if [ "${FAKE_CONSUMER_RECOMPILE:-0}" = '1' ]; then
            printf '%s\n' \
                'swiftc -frontend -c -module-name MojoRuntime' >&2
        fi
        ;;
esac

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
        */production/swift-mojo)
            test -f "$package_path/Package.swift"
            ;;
        *)
            echo "verified phase received an unverified package path: $package_path" >&2
            exit 1
            ;;
    esac
fi

if [ "$phase" = 'verified-source-v1' ] \
    && [ "$product" = 'runtime-worker-acceptance' ] \
    && [ "${FAKE_VERIFIED_BUILD_DELAY_SECONDS:-0}" != '0' ]; then
    /bin/sleep "$FAKE_VERIFIED_BUILD_DELAY_SECONDS"
fi

if [ "$plugin_command" = 'runtime-worker-prepare' ]; then
    printf '%s\n' \
        'swiftc -frontend -c -module-name MojoCommandPlugin' \
        'swiftc -frontend -c -module-name swift_mojo' >&2
    output=''
    previous=''
    for argument in "$@"; do
        if [ "$previous" = '--output' ]; then
            output="$argument"
        fi
        previous="$argument"
    done
    verified_source_root="${package_path%/Acceptance/RuntimeWorker}"
    source_root="$package_path"
    source="$source_root/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    source_relative="Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    printf 'fake-authoring package=%s source-root=%s source=%s repository=%s\n' \
        "$package_path" "$source_root" "$source" "$repository_root" >&2
    if [ -n "${FAKE_SWIFT_TRACE_PATH:-}" ]; then
        printf 'fake-authoring package=%s source-root=%s source=%s repository=%s\n' \
            "$package_path" "$source_root" "$source" "$repository_root" \
            >> "$FAKE_SWIFT_TRACE_PATH"
    fi
    test -f "$verified_source_root/.verified-source-snapshot"
    test -f "$source"
    test "$binding_source_count" -eq 1
    test "$binding_source" = "$source_relative"
    test "$raw_source_option" -eq 0
    case "$repository_root" in
        */production/swift-mojo) ;;
        *) echo 'authoring dependency root did not come from production archive' >&2; exit 1 ;;
    esac
    test "$output" != ''
    /bin/mkdir -p "$output"
    : > "$output/manifest.json"
    exit 0
fi

if [ "$plugin_command" = 'runtime-worker-verify' ]; then
    printf '%s\n' \
        'swiftc -frontend -c -module-name MojoCommandPlugin' \
        'swiftc -frontend -c -module-name swift_mojo' >&2
    printf '%s\n' 'fake-runtime-worker-verify=passed' >&2
    exit 0
fi

if [ "${1:-}" = 'build' ] && [ "$product" != '' ]; then
    executable="$FAKE_BUILD_BIN/$product"
    case "$product" in
        RuntimeWorkerAcceptanceConsumer)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
exit 0
SCRIPT
            ;;
        runtime-worker-acceptance|runtime-worker-acceptance-source)
            cat > "$executable" <<'SCRIPT'
#!/bin/sh
set -eu

if [ "${1:-}" = '--execute-verified-source-at' ]; then
    if [ "${FAKE_SOURCE_RUNNER_DELAY_SECONDS:-0}" != '0' ]; then
        /bin/sleep "$FAKE_SOURCE_RUNNER_DELAY_SECONDS"
    fi
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
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel"
    /bin/cp "$source_root/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/runtime-worker-acceptance.sh"
    /bin/cp "$source_root/scripts/command-timeout.sh" \
        "$destination/scripts/command-timeout.sh"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/SwiftMojo.json" \
        "$destination/Acceptance/RuntimeWorker/SwiftMojo.json"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/RuntimeWorkerAcceptanceModelInventory.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/RuntimeWorkerAcceptanceModelInventory.swift"
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
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel"
    /bin/cp "$source_root/scripts/runtime-worker-acceptance.sh" \
        "$destination/scripts/runtime-worker-acceptance.sh"
    /bin/cp "$source_root/scripts/command-timeout.sh" \
        "$destination/scripts/command-timeout.sh"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/Package.swift" \
        "$destination/Acceptance/RuntimeWorker/Package.swift"
    /bin/cp "$source_root/Acceptance/RuntimeWorker/SwiftMojo.json" \
        "$destination/Acceptance/RuntimeWorker/SwiftMojo.json"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    /bin/cp \
        "$source_root/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/RuntimeWorkerAcceptanceModelInventory.swift" \
        "$destination/Acceptance/RuntimeWorker/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/RuntimeWorkerAcceptanceModelInventory.swift"
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
    printf '%s\n' "$!" > "$tmpdir/fake-worker.pid"
    /bin/sleep 1
elif [ "$mode" = 'writer' ]; then
    TARGET_W="$tmpdir" /usr/bin/perl -MPOSIX -e \
        'POSIX::setsid() or die $!; exec "/bin/sh", "-c", q{/bin/sleep 30; /bin/mkdir -p "$TARGET_W/recreated"} or die $!;' \
        >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$tmpdir/delayed-writer.pid"
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

cat > "$fake_slow_rm_bin/rm" <<'EOF'
#!/bin/sh
set -eu
delay_cleanup=0
for argument in "$@"; do
    case "$argument" in
        */swift-mojo-rt4b.*) delay_cleanup=1 ;;
    esac
done
if [ "$delay_cleanup" -eq 1 ]; then
    /bin/sleep 3
fi
exec /bin/rm "$@"
EOF

/bin/chmod +x \
    "$fake_bin/mojo" \
    "$fake_bin/swift" \
    "$fake_rm_bin/rm" \
    "$fake_slow_rm_bin/rm"

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

assert_no_acceptance_process() {
    local case_tmpdir="$1"
    local process_listing="$TEST_ROOT/acceptance-process-listing.txt"
    /bin/ps -axo pid=,pgid=,command= > "$process_listing"
    if /usr/bin/grep -F \
        "$case_tmpdir/swift-mojo-rt4b." \
        "$process_listing" >/dev/null; then
        echo "acceptance process survived outer termination for $case_tmpdir" >&2
        /usr/bin/grep -F \
            "$case_tmpdir/swift-mojo-rt4b." \
            "$process_listing" >&2
        exit 1
    fi
}

run_acceptance() {
    local case_tmpdir="$1"
    local case_path="$2"
    local output_path="$3"
    local source_digest_mismatch="${4:-0}"
    local controller_mode="${5:-clean}"
    local direct_signal_delay_seconds="${6:-0}"
    local verified_build_delay_seconds="${7:-0}"
    local direct_signal_name="${8:-TERM}"
    local bootstrap_forbidden_module="${9:-0}"
    local consumer_recompile="${10:-0}"
    mkdir -p "$case_tmpdir"
    local acceptance_command=(/usr/bin/env \
        "MODULAR_HOME=$fake_modular_home" \
        "SWIFT_MOJO_EXECUTABLE=$fake_bin/mojo" \
        "FAKE_BUILD_BIN=$fake_build_bin" \
        "FAKE_SOURCE_DIGEST_MISMATCH=$source_digest_mismatch" \
        "FAKE_CONTROLLER_MODE=$controller_mode" \
        "FAKE_VERIFIED_BUILD_DELAY_SECONDS=$verified_build_delay_seconds" \
        "FAKE_SWIFT_TRACE_PATH=$case_tmpdir/fake-swift.trace" \
        "FAKE_BOOTSTRAP_FORBIDDEN_MODULE=$bootstrap_forbidden_module" \
        "FAKE_CONSUMER_RECOMPILE=$consumer_recompile" \
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
        --runtime-library "$fake_modular_home/lib/libAsyncRTRuntimeGlobals.dylib")
    if [[ "$direct_signal_delay_seconds" != 0 ]]; then
        /usr/bin/perl -e '
            $SIG{TERM} = "DEFAULT";
            $SIG{INT} = "DEFAULT";
            $SIG{HUP} = "DEFAULT";
            exec { $ARGV[0] } @ARGV or die "exec: $!\n";
        ' "${acceptance_command[@]}" > "$output_path" 2>&1 &
        local acceptance_pid=$!
        /bin/sleep "$direct_signal_delay_seconds"
        /bin/kill -s "$direct_signal_name" "$acceptance_pid"
        wait "$acceptance_pid"
        return $?
    fi
    "${acceptance_command[@]}" > "$output_path" 2>&1
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
    local bindings_source="$acceptance_root/Fixtures/RuntimeWorkerAcceptanceModel/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
    local bootstrap_build="$work_dir/acceptance-bootstrap-build"
    local verified_build="$work_dir/verified-build"
    local expected_digest="$(printf '%064d' 0)"
    local swift_trace="$case_tmpdir/fake-swift.trace"

    /usr/bin/grep -Fq \
        "fake-swift phase=bootstrap product=runtime-worker-acceptance-source package=$REPOSITORY_ROOT/Acceptance/RuntimeWorker repository=$REPOSITORY_ROOT scratch=$bootstrap_build" \
        "$swift_trace"
    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product=runtime-worker-acceptance package=$acceptance_root repository=$production_root scratch=$verified_build" \
        "$swift_trace"
    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product= package=$acceptance_root repository=$production_root scratch=$verified_build" \
        "$swift_trace"
    /usr/bin/grep -Fq \
        "fake-swift phase=verified-source-v1 product=RuntimeWorkerAcceptanceConsumer package=$acceptance_root repository=$production_root scratch=$verified_build" \
        "$swift_trace"
    /usr/bin/grep -Fq \
        "fake-authoring package=$acceptance_root source-root=$acceptance_root source=$bindings_source repository=$production_root" \
        "$swift_trace"
    if /usr/bin/grep -Fq \
        "product=swift-mojo package=$production_root" \
        "$swift_trace"; then
        echo "authoring rebuilt swift-mojo as a root package" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    /usr/bin/grep -Fq \
        "fake-source-digest-root=$actual_snapshot_root" \
        "$output_path"
    /usr/bin/grep -Fq \
        "fake-controller repository=$actual_snapshot_root digest=$expected_digest revision=$EXPECTED_REVISION" \
        "$output_path"
    if /usr/bin/grep -F 'phase=verified-source-v1' "$swift_trace" | \
        /usr/bin/grep -Fq "package=$REPOSITORY_ROOT"; then
        echo "verified phase read a live-repository package path" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    if /usr/bin/grep -F 'phase=verified-source-v1' "$swift_trace" | \
        /usr/bin/grep -Fq "scratch=$bootstrap_build"; then
        echo "verified phase reused the live bootstrap scratch" >&2
        /bin/cat "$output_path" >&2
        exit 1
    fi
    /usr/bin/grep -Fq \
        'runtime-worker-acceptance build-log phase=bootstrap compiled-modules=2' \
        "$output_path"
    /usr/bin/grep -Fq \
        'runtime-worker-acceptance build-log phase=verified runner=3 authoring=2 consumer=1 overlaps=0' \
        "$output_path"
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

bootstrap_scope_tmpdir="$TEST_ROOT/bootstrap-scope-tmp"
bootstrap_scope_output="$TEST_ROOT/bootstrap-scope-output.log"
set +e
run_acceptance \
    "$bootstrap_scope_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$bootstrap_scope_output" \
    0 \
    clean \
    0 \
    0 \
    TERM \
    1
exit_status=$?
set -e
if ((exit_status != 1)); then
    echo "expected forbidden bootstrap module to exit 1, got $exit_status" >&2
    /bin/cat "$bootstrap_scope_output" >&2
    exit 1
fi
if ! /usr/bin/grep -Fq \
    'bootstrap compiled a forbidden heavy module: MojoRuntime' \
    "$bootstrap_scope_output"; then
    echo 'forbidden bootstrap compilation was not reported' >&2
    /bin/cat "$bootstrap_scope_output" >&2
    exit 1
fi
assert_no_acceptance_temp "$bootstrap_scope_tmpdir"

phase_overlap_tmpdir="$TEST_ROOT/phase-overlap-tmp"
phase_overlap_output="$TEST_ROOT/phase-overlap-output.log"
set +e
run_acceptance \
    "$phase_overlap_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$phase_overlap_output" \
    0 \
    clean \
    0 \
    0 \
    TERM \
    0 \
    1
exit_status=$?
set -e
if ((exit_status != 1)); then
    echo "expected repeated module compilation to exit 1, got $exit_status" >&2
    /bin/cat "$phase_overlap_output" >&2
    exit 1
fi
if ! /usr/bin/grep -Fq \
    'module compilation repeated across runner and consumer' \
    "$phase_overlap_output"; then
    echo 'cross-phase module recompilation was not reported' >&2
    /bin/cat "$phase_overlap_output" >&2
    exit 1
fi
assert_no_acceptance_temp "$phase_overlap_tmpdir"

aborted_tmpdir="$TEST_ROOT/aborted-tmp"
aborted_output="$TEST_ROOT/aborted-output.log"
aborted_started_seconds=$SECONDS
set +e
run_acceptance \
    "$aborted_tmpdir" \
    "$fake_slow_rm_bin:$fake_bin:/usr/bin:/bin" \
    "$aborted_output" \
    0 \
    clean \
    1 \
    30
exit_status=$?
set -e
if ((exit_status != 143)); then
    echo "expected direct TERM to exit 143, got $exit_status" >&2
    /bin/cat "$aborted_output" >&2
    exit 1
fi
if ((SECONDS - aborted_started_seconds < 3)); then
    echo "acceptance supervisor returned before slow cleanup completed" >&2
    /bin/cat "$aborted_output" >&2
    exit 1
fi
if /usr/bin/grep -Eq \
    '^(fake-authoring|fake-controller|fake-swift .*product=RuntimeWorkerAcceptanceConsumer)' \
    "$aborted_output"; then
    echo "acceptance started a later verified phase after cancellation" >&2
    /bin/cat "$aborted_output" >&2
    exit 1
fi
assert_no_acceptance_process "$aborted_tmpdir"
assert_no_acceptance_temp "$aborted_tmpdir"

for signal_case in "INT:130" "HUP:129"; do
    signal_name="${signal_case%%:*}"
    expected_signal_status="${signal_case##*:}"
    signal_tmpdir="$TEST_ROOT/signal-$signal_name-tmp"
    signal_output="$TEST_ROOT/signal-$signal_name-output.log"
    set +e
    run_acceptance \
        "$signal_tmpdir" \
        "$fake_bin:/usr/bin:/bin" \
        "$signal_output" \
        0 \
        clean \
        1 \
        30 \
        "$signal_name"
    exit_status=$?
    set -e
    if ((exit_status != expected_signal_status)); then
        echo "expected direct $signal_name to exit $expected_signal_status, got $exit_status" >&2
        /bin/cat "$signal_output" >&2
        exit 1
    fi
    assert_no_acceptance_process "$signal_tmpdir"
    assert_no_acceptance_temp "$signal_tmpdir"
done

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

if ((exit_status != 70)); then
    echo "expected cleanup failure to exit 70, got $exit_status" >&2
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

if ((exit_status != 70)); then
    echo "expected preserved worker leak to exit 70, got $exit_status" >&2
    /bin/cat "$leak_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q 'acceptance cleanup preserved unowned worker process' \
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
if ! /usr/bin/grep -q \
    'acceptance supervisor preserved work directory after an inherited process lease remained open' \
    "$leak_output"; then
    echo 'unowned worker work directory was not preserved' >&2
    /bin/cat "$leak_output" >&2
    exit 1
fi
leaked_worker_pid_file="$(
    /usr/bin/find "$leak_tmpdir" -name fake-worker.pid -type f -print -quit
)"
if [[ -z "$leaked_worker_pid_file" ]]; then
    echo "fake leaked worker PID file is missing" >&2
    exit 1
fi
leaked_worker_pid="$(/bin/cat "$leaked_worker_pid_file")"
if [[ ! "$leaked_worker_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "fake leaked worker PID is invalid: $leaked_worker_pid" >&2
    exit 1
fi
leaked_worker_command="$(
    /bin/ps -p "$leaked_worker_pid" -o command= 2>/dev/null || true
)"
if [[ "$leaked_worker_command" != *"$leak_tmpdir/"*"/swift-mojo-worker-"* ]]; then
    echo "fake leaked worker identity changed before test cleanup" >&2
    exit 1
fi
/bin/kill -KILL "-$leaked_worker_pid"
for _ in 1 2 3 4 5; do
    /bin/kill -0 "$leaked_worker_pid" 2>/dev/null || break
    /bin/sleep 1
done
assert_no_worker_process "$leak_tmpdir"
/usr/bin/find "$leak_tmpdir" -type d -exec /bin/chmod u+w {} +
/bin/rm -rf -- "$leak_tmpdir"

writer_tmpdir="$TEST_ROOT/writer-tmp"
writer_output="$TEST_ROOT/writer-output.log"

set +e
run_acceptance \
    "$writer_tmpdir" \
    "$fake_bin:/usr/bin:/bin" \
    "$writer_output" \
    0 \
    writer
exit_status=$?
set -e

if ((exit_status != 70)); then
    echo "expected preserved W-bound writer to exit 70, got $exit_status" >&2
    /bin/cat "$writer_output" >&2
    exit 1
fi
if ! /usr/bin/grep -q \
    'acceptance supervisor preserved work directory after an inherited process lease remained open' \
    "$writer_output"; then
    echo 'W-bound writer process was not reported' >&2
    /bin/cat "$writer_output" >&2
    exit 1
fi
writer_pid_file="$(
    /usr/bin/find "$writer_tmpdir" -name delayed-writer.pid -type f -print -quit
)"
if [[ -z "$writer_pid_file" ]]; then
    echo "delayed writer PID file is missing" >&2
    exit 1
fi
writer_pid="$(/bin/cat "$writer_pid_file")"
if [[ ! "$writer_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "delayed writer PID is invalid: $writer_pid" >&2
    exit 1
fi
/bin/kill -KILL "-$writer_pid"
for _ in 1 2 3 4 5; do
    /bin/kill -0 "$writer_pid" 2>/dev/null || break
    /bin/sleep 1
done
/usr/bin/find "$writer_tmpdir" -type d -exec /bin/chmod u+w {} +
/bin/rm -rf -- "$writer_tmpdir"

echo 'runtime-worker-acceptance verified-source, failure, and cleanup paths passed'
