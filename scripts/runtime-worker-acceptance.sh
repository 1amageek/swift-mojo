#!/usr/bin/env bash

set -euo pipefail

# This script authors an ephemeral worker bundle, verifies it, and delegates
# the actual-host lifecycle check to the acceptance controller. It never writes
# a receipt or leaves generated binaries in the repository.

readonly VERIFIED_INVOCATION_NAME="swift-mojo-runtime-worker-acceptance-verified-v1"

if ((${#BASH_SOURCE[@]} != 0)); then
    readonly LIVE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    readonly LIVE_REPOSITORY_ROOT="$(cd "$LIVE_SCRIPT_DIR/.." && pwd)"
    readonly LIVE_ACCEPTANCE_ROOT="$LIVE_REPOSITORY_ROOT/Acceptance/RuntimeWorker"
    readonly LIVE_COMMAND_TIMEOUT="$LIVE_REPOSITORY_ROOT/scripts/command-timeout.sh"

    if [[ ! -x "$LIVE_COMMAND_TIMEOUT" ]]; then
        echo "bounded command helper is unavailable: $LIVE_COMMAND_TIMEOUT" >&2
        exit 2
    fi

    readonly BOOTSTRAP_TIMEOUT_SECONDS="${RT4_TIMEOUT_SECONDS:-600}"
    readonly BOOTSTRAP_WORK_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd)"
    bootstrap_work_dir=""
    bootstrap_requested_exit_status=0
    bootstrap_requested_signal_name=""
    bootstrap_cancel_term_file=""
    bootstrap_cancel_int_file=""
    bootstrap_cancel_hup_file=""
    bootstrap_cancel_gate_lock_directory=""
    bootstrap_cancellation_publish_failed=0
    bootstrap_capture_sequence=0

    bootstrap_publish_cancellation() {
        local cancellation_path=""
        local gate_acquired=0
        case "$bootstrap_requested_signal_name" in
            TERM) cancellation_path="$bootstrap_cancel_term_file" ;;
            INT) cancellation_path="$bootstrap_cancel_int_file" ;;
            HUP) cancellation_path="$bootstrap_cancel_hup_file" ;;
            "") return 0 ;;
            *)
                bootstrap_cancellation_publish_failed=1
                return 1
                ;;
        esac
        [[ -n "$cancellation_path" ]] || return 0
        if [[ -n "$bootstrap_cancel_gate_lock_directory" ]]; then
            if /bin/mkdir -- "$bootstrap_cancel_gate_lock_directory" \
                2>/dev/null; then
                gate_acquired=1
            fi
        fi
        if ! : > "$cancellation_path"; then
            bootstrap_cancellation_publish_failed=1
            if ((gate_acquired != 0)); then
                /bin/rmdir -- "$bootstrap_cancel_gate_lock_directory" \
                    2>/dev/null || true
            fi
            return 1
        fi
        if ((gate_acquired != 0)) \
            && ! /bin/rmdir -- "$bootstrap_cancel_gate_lock_directory"; then
            bootstrap_cancellation_publish_failed=1
            return 1
        fi
    }

    bootstrap_latch_signal() {
        local signal_name="$1"
        local requested_status="$2"
        if ((bootstrap_requested_exit_status != 0)); then
            return 0
        fi
        bootstrap_requested_exit_status="$requested_status"
        bootstrap_requested_signal_name="$signal_name"
        bootstrap_publish_cancellation || true
    }

    bootstrap_remove_work_directory() {
        [[ -n "$bootstrap_work_dir" ]] || return 0
        case "$bootstrap_work_dir" in
            "$BOOTSTRAP_WORK_ROOT"/swift-mojo-rt4b.??????) ;;
            *)
                echo "acceptance cleanup rejected an invalid work directory: $bootstrap_work_dir" >&2
                return 1
                ;;
        esac
        if [[ -d "$bootstrap_work_dir" ]]; then
            find "$bootstrap_work_dir" -type d -exec chmod u+w {} + \
                || return 1
        fi
        if ! rm -rf -- "$bootstrap_work_dir"; then
            echo "acceptance work directory cleanup failed: $bootstrap_work_dir" >&2
            return 1
        fi
        if [[ -e "$bootstrap_work_dir" || -L "$bootstrap_work_dir" ]]; then
            echo "acceptance work directory remains after cleanup: $bootstrap_work_dir" >&2
            return 1
        fi
    }

    bootstrap_early_cleanup() {
        local previous_status=$?
        trap - EXIT
        trap '' TERM INT HUP
        if ! bootstrap_remove_work_directory; then
            exit 70
        fi
        exit "$previous_status"
    }
    trap bootstrap_early_cleanup EXIT
    trap 'bootstrap_latch_signal INT 130' INT
    trap 'bootstrap_latch_signal TERM 143' TERM
    trap 'bootstrap_latch_signal HUP 129' HUP

    bootstrap_work_dir_candidate="$(
        mktemp -d "$BOOTSTRAP_WORK_ROOT/swift-mojo-rt4b.XXXXXX"
    )"
    bootstrap_work_dir="$(cd "$bootstrap_work_dir_candidate" && pwd)"
    unset bootstrap_work_dir_candidate
    case "$bootstrap_work_dir" in
        "$BOOTSTRAP_WORK_ROOT"/swift-mojo-rt4b.??????) ;;
        *)
            echo "acceptance bootstrap returned an invalid work directory" >&2
            exit 1
            ;;
    esac
    bootstrap_cancel_term_file="$bootstrap_work_dir/cancel-term"
    bootstrap_cancel_int_file="$bootstrap_work_dir/cancel-int"
    bootstrap_cancel_hup_file="$bootstrap_work_dir/cancel-hup"
    bootstrap_cancel_gate_lock_directory="$bootstrap_work_dir/cancel-gate-lock"
    bootstrap_publish_cancellation || true

    bootstrap_wait_for_bounded() {
        local bounded_pid="$1"
        local bounded_status=0
        if wait "$bounded_pid"; then
            bounded_status=0
        else
            bounded_status=$?
        fi
        if ((bootstrap_requested_exit_status != 0)); then
            # The first wait can be interrupted by the shell trap before the
            # bounded child exits. Ignore subsequent signals and wait once
            # more so the exact child is either reaped here or already reaped.
            trap '' TERM INT HUP
            wait "$bounded_pid" 2>/dev/null || true
            return "$bootstrap_requested_exit_status"
        fi
        return "$bounded_status"
    }

    run_bootstrap_bounded() {
        local seconds="$1"
        shift
        if ((bootstrap_cancellation_publish_failed != 0)); then
            echo "acceptance supervisor could not publish cancellation" >&2
            return 70
        fi
        if ((bootstrap_requested_exit_status != 0)); then
            return "$bootstrap_requested_exit_status"
        fi
        COMMAND_TIMEOUT_TERM_FILE="$bootstrap_cancel_term_file" \
        COMMAND_TIMEOUT_INT_FILE="$bootstrap_cancel_int_file" \
        COMMAND_TIMEOUT_HUP_FILE="$bootstrap_cancel_hup_file" \
        COMMAND_TIMEOUT_GATE_LOCK_DIRECTORY="$bootstrap_cancel_gate_lock_directory" \
            "$LIVE_COMMAND_TIMEOUT" "$seconds" -- "$@" &
        local bounded_pid=$!
        bootstrap_wait_for_bounded "$bounded_pid"
    }

    run_bootstrap_bounded_capture() {
        local result_name="$1"
        local seconds="$2"
        shift 2
        bootstrap_capture_sequence=$((bootstrap_capture_sequence + 1))
        local capture_path="$bootstrap_work_dir/bootstrap-output-$bootstrap_capture_sequence"
        local command_status=0
        run_bootstrap_bounded "$seconds" "$@" > "$capture_path" \
            || command_status=$?
        if ((command_status != 0)); then
            return "$command_status"
        fi
        printf -v "$result_name" '%s' "$(< "$capture_path")"
    }

    bootstrap_require_no_worker_processes() {
        local worker_prefix="$bootstrap_work_dir/execution-tmp/swift-mojo-worker-"
        local process_command="/bin/ps"
        [[ -x "$process_command" ]] || process_command="/usr/bin/ps"
        if [[ ! -x "$process_command" ]]; then
            echo "acceptance supervisor cannot inspect worker processes" >&2
            return 1
        fi

        local process_listing=""
        process_listing="$($process_command -axo pid=,pgid=,command=)" \
            || return 1
        local line=""
        while IFS= read -r line; do
            if [[ "$line" == *"$worker_prefix"* ]]; then
                echo "acceptance supervisor preserved unowned worker process: $line" >&2
                return 1
            fi
        done <<< "$process_listing"
        return 0
    }

    bootstrap_cleanup() {
        local previous_status=$?
        trap - EXIT
        trap '' TERM INT HUP
        local cleanup_status=0
        bootstrap_require_no_worker_processes || cleanup_status=1
        if ((cleanup_status == 0)); then
            bootstrap_remove_work_directory || cleanup_status=1
        else
            echo "acceptance supervisor preserved work directory after losing process authority: $bootstrap_work_dir" >&2
        fi
        if ((cleanup_status != 0)); then
            exit 70
        fi
        exit "$previous_status"
    }
    trap bootstrap_cleanup EXIT

    if ((bootstrap_cancellation_publish_failed != 0)); then
        echo "acceptance supervisor could not publish cancellation" >&2
        exit 70
    fi
    if ((bootstrap_requested_exit_status != 0)); then
        exit "$bootstrap_requested_exit_status"
    fi

    bootstrap_build_args=(
        env "SWIFT_MOJO_REPOSITORY_ROOT=$LIVE_REPOSITORY_ROOT"
        swift build
        --package-path "$LIVE_ACCEPTANCE_ROOT"
        --product runtime-worker-acceptance-source
        --configuration release
        --scratch-path "$bootstrap_work_dir/acceptance-bootstrap-build"
        --disable-sandbox
        --force-resolved-versions
    )
    bootstrap_build_started_seconds=$SECONDS
    run_bootstrap_bounded "$BOOTSTRAP_TIMEOUT_SECONDS" \
        "${bootstrap_build_args[@]}"
    printf 'runtime-worker-acceptance phase=bootstrap-build seconds=%d\n' \
        "$((SECONDS - bootstrap_build_started_seconds))" >&2
    bootstrap_runner_bin_dir=""
    run_bootstrap_bounded_capture \
        bootstrap_runner_bin_dir "$BOOTSTRAP_TIMEOUT_SECONDS" env \
            "SWIFT_MOJO_REPOSITORY_ROOT=$LIVE_REPOSITORY_ROOT" swift build \
            --package-path "$LIVE_ACCEPTANCE_ROOT" \
            --configuration release \
            --scratch-path "$bootstrap_work_dir/acceptance-bootstrap-build" \
            --disable-sandbox \
            --force-resolved-versions \
            --show-bin-path
    bootstrap_runner="$bootstrap_runner_bin_dir/runtime-worker-acceptance-source"
    if [[ ! -x "$bootstrap_runner" ]]; then
        echo "runtime-worker acceptance bootstrap was not produced: $bootstrap_runner" >&2
        exit 1
    fi

    source_snapshot_root="$bootstrap_work_dir/acceptance-source"
    run_bootstrap_bounded "$BOOTSTRAP_TIMEOUT_SECONDS" \
        "$bootstrap_runner" \
        --execute-verified-source-at "$LIVE_REPOSITORY_ROOT" \
        --destination "$source_snapshot_root" \
        --live-git-root "$LIVE_REPOSITORY_ROOT" \
        -- "$@"
    exit 0
fi

if [[ "$0" != "$VERIFIED_INVOCATION_NAME" ]]; then
    echo "verified acceptance invocation identity is invalid" >&2
    exit 1
fi

if (($# < 3)); then
    echo "verified acceptance invocation is incomplete" >&2
    exit 1
fi
readonly VERIFIED_SOURCE_ARGUMENT="$1"
readonly LIVE_GIT_ROOT_ARGUMENT="$2"
readonly ACCEPTANCE_SOURCE_DIGEST="$3"
shift 3

readonly REPOSITORY_ROOT="$(cd "$VERIFIED_SOURCE_ARGUMENT" && pwd)"
readonly LIVE_GIT_REPOSITORY_ROOT="$(cd "$LIVE_GIT_ROOT_ARGUMENT" && pwd)"
readonly WORK_DIR="$(cd "$REPOSITORY_ROOT/.." && pwd)"
readonly PRODUCTION_ROOT="$WORK_DIR/production/swift-mojo"
readonly VERIFIED_BUILD_ROOT="$WORK_DIR/verified-build"
readonly ACCEPTANCE_ROOT="$REPOSITORY_ROOT/Acceptance/RuntimeWorker"
readonly MODEL_ROOT="$ACCEPTANCE_ROOT/Fixtures/RuntimeWorkerAcceptanceModel"
readonly CONSUMER_ROOT="$ACCEPTANCE_ROOT/Fixtures/Consumer"
readonly BINDINGS_SOURCE="$MODEL_ROOT/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
readonly COMMAND_TIMEOUT="$REPOSITORY_ROOT/scripts/command-timeout.sh"

if [[ "${REPOSITORY_ROOT##*/}" != "acceptance-source" \
    || "$REPOSITORY_ROOT" != "$WORK_DIR/acceptance-source" \
    || ! "${WORK_DIR##*/}" =~ ^swift-mojo-rt4b\.[[:alnum:]]{6}$ ]]; then
    echo "verified acceptance source is outside its fixed private layout" >&2
    exit 1
fi
if [[ ! "$ACCEPTANCE_SOURCE_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    echo "acceptance source digest is not lowercase SHA-256" >&2
    exit 1
fi

target_triple=""
target_cpu=""
target_accelerator=""
maximum_frame_payload_bytes="65536"
dry_run=false
declare -a runtime_libraries=()
declare -a system_libraries=()

usage() {
    cat <<'EOF'
Usage: runtime-worker-acceptance.sh [options]

Authoring requires MODULAR_HOME and SWIFT_MOJO_EXECUTABLE to be set to the
pinned Mojo 1.0.0 (ed45d567) installation. Execution is later run with an
empty PATH and without compiler, Python, or loader environment variables.

Options:
  --dry-run
  --target-triple <triple>
  --target-cpu <cpu>
  --target-accelerator <accelerator>
  --runtime-library <path>       (repeatable; required at least once)
  --system-library <path>        (repeatable)
EOF
}

while (($# > 0)); do
    case "$1" in
        --dry-run)
            dry_run=true
            shift
            ;;
        --target-triple|--target-cpu|--target-accelerator|--runtime-library|--system-library)
            if (($# < 2)) || [[ "$2" == --* ]]; then
                echo "missing value for $1" >&2
                exit 2
            fi
            case "$1" in
                --target-triple) target_triple="$2" ;;
                --target-cpu) target_cpu="$2" ;;
                --target-accelerator) target_accelerator="$2" ;;
                --runtime-library) runtime_libraries+=("$2") ;;
                --system-library) system_libraries+=("$2") ;;
            esac
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "unknown option $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for target_option in target_triple target_cpu target_accelerator; do
    if [[ -z "${!target_option}" ]]; then
        echo "--${target_option//_/-} is required" >&2
        usage >&2
        exit 2
    fi
done
if ((${#runtime_libraries[@]} == 0)); then
    echo "at least one --runtime-library is required" >&2
    usage >&2
    exit 2
fi

if [[ "$dry_run" == true ]]; then
    cat <<EOF
authoring target: $target_triple / $target_cpu / $target_accelerator
source: $BINDINGS_SOURCE
authoring: runtime-worker-prepare with pinned Mojo 1.0.0 (ed45d567)
verification: public FileSystemMojoRuntimeWorkerBundleVerifier
execution: empty PATH, no MODULAR_HOME/SWIFT_MOJO/Python/loader variables
consumer: public MojoRuntime + MojoRuntimeWorker only
EOF
    exit 0
fi

: "${MODULAR_HOME:?MODULAR_HOME must point to the pinned Mojo environment}"
: "${SWIFT_MOJO_EXECUTABLE:?SWIFT_MOJO_EXECUTABLE must point to the pinned mojo executable}"

if [[ ! -x "$SWIFT_MOJO_EXECUTABLE" ]]; then
    echo "SWIFT_MOJO_EXECUTABLE is not executable: $SWIFT_MOJO_EXECUTABLE" >&2
    exit 2
fi
if [[ ! -d "$MODULAR_HOME" ]]; then
    echo "MODULAR_HOME is not a directory: $MODULAR_HOME" >&2
    exit 2
fi
if [[ ! -x "$COMMAND_TIMEOUT" ]]; then
    echo "bounded command helper is unavailable: $COMMAND_TIMEOUT" >&2
    exit 2
fi

timeout_seconds="${RT4_TIMEOUT_SECONDS:-600}"
run_bounded() {
    local seconds="$1"
    shift
    "$COMMAND_TIMEOUT" "$seconds" -- "$@"
}

compiler_version="$(run_bounded "$timeout_seconds" "$SWIFT_MOJO_EXECUTABLE" --version)"
if [[ "$compiler_version" != "Mojo 1.0.0 (ed45d567)" ]]; then
    echo "unsupported Mojo compiler: $compiler_version" >&2
    exit 2
fi

if ((${#system_libraries[@]} == 0)); then
    if [[ "$target_triple" != *apple-macosx* ]]; then
        echo "Linux authoring requires at least one --system-library" >&2
        exit 2
    fi
fi
if [[ "$target_triple" == *apple-macosx* ]] \
    && ((${#system_libraries[@]} > 0)); then
    echo "Mac authoring does not accept explicit system dependencies" >&2
    exit 2
fi

for library in "${runtime_libraries[@]}"; do
    if [[ ! -f "$library" ]]; then
        echo "declared library does not exist: $library" >&2
        exit 2
    fi
done
if ((${#system_libraries[@]} > 0)); then
    for library in "${system_libraries[@]}"; do
        if [[ -z "$library" ]]; then
            echo "declared system library is empty" >&2
            exit 2
        fi
    done
fi

if [[ ! -f "$BINDINGS_SOURCE" ]]; then
    echo "canonical binding source is missing: $BINDINGS_SOURCE" >&2
    exit 2
fi
work_dir="$WORK_DIR"
case "$REPOSITORY_ROOT" in
    "$work_dir"/*) ;;
    *)
        echo "verified source snapshot is outside the private work directory" >&2
        exit 1
        ;;
esac
case "$PRODUCTION_ROOT" in
    "$work_dir"/*) ;;
    *)
        echo "production archive is outside the private work directory" >&2
        exit 1
        ;;
esac
execution_tmp=""
worker_process_prefix=""
worker_process_leak_observed=false
worker_stage_leak_observed=false
cleanup() {
    local previous_status=$?
    trap - EXIT
    local cleanup_status=0
    if [[ -n "$worker_process_prefix" && -n "$execution_tmp" ]]; then
        if worker_stage_exists; then
            worker_stage_leak_observed=true
            echo "acceptance cleanup observed leaked worker stage: $worker_process_prefix*" >&2
        fi
        require_no_unowned_worker_processes || cleanup_status=1
    fi
    if ((previous_status == 0)) \
        && [[ "$worker_process_leak_observed" == true \
            || "$worker_stage_leak_observed" == true ]]; then
        exit 1
    fi
    if ((cleanup_status != 0 && previous_status == 0)); then
        exit 1
    fi
    exit "$previous_status"
}
trap cleanup EXIT

worker_stage_exists() {
    local stage_path=""
    for stage_path in "$execution_tmp"/swift-mojo-worker-*; do
        if [[ -e "$stage_path" || -L "$stage_path" ]]; then
            return 0
        fi
    done
    return 1
}

require_no_unowned_worker_processes() {
    local process_command="/bin/ps"
    if [[ ! -x "$process_command" ]]; then
        process_command="/usr/bin/ps"
    fi
    if [[ ! -x "$process_command" ]]; then
        echo "acceptance cleanup cannot inspect processes" >&2
        return 1
    fi

    local process_listing
    if ! process_listing="$(run_bounded 5 "$process_command" -axo pid=,pgid=,command=)"; then
        echo "acceptance cleanup could not inspect worker processes" >&2
        return 1
    fi

    local line=""
    while IFS= read -r line; do
        if [[ "$line" == *"$worker_process_prefix"* ]]; then
            worker_process_leak_observed=true
            echo "acceptance cleanup preserved unowned worker process: $line" >&2
            return 1
        fi
    done <<< "$process_listing"
    return 0
}

resolved_git_root="$(run_bounded "$timeout_seconds" git \
    -C "$LIVE_GIT_REPOSITORY_ROOT" rev-parse --show-toplevel)"
if [[ "$(cd "$resolved_git_root" && pwd)" != "$LIVE_GIT_REPOSITORY_ROOT" ]]; then
    echo "live Git object authority does not match the bootstrap repository" >&2
    exit 1
fi
swift_mojo_revision="$(run_bounded "$timeout_seconds" git \
    -C "$LIVE_GIT_REPOSITORY_ROOT" rev-parse --verify 'HEAD^{commit}')"
if [[ ! "$swift_mojo_revision" =~ ^[0-9a-f]{40}$ ]]; then
    echo "swift-mojo HEAD is not a lowercase 40-character Git object ID" >&2
    exit 1
fi
readonly SWIFT_MOJO_REVISION="$swift_mojo_revision"

production_archive="$work_dir/swift-mojo.tar"
mkdir -p "$PRODUCTION_ROOT"
run_bounded "$timeout_seconds" git \
    -C "$LIVE_GIT_REPOSITORY_ROOT" archive \
    --format=tar \
    --output="$production_archive" \
    "$SWIFT_MOJO_REVISION"
run_bounded "$timeout_seconds" tar \
    -xf "$production_archive" -C "$PRODUCTION_ROOT"
find "$PRODUCTION_ROOT" -type f -exec chmod 0444 {} +
find "$PRODUCTION_ROOT" -type d -exec chmod 0555 {} +

runner_build_args=(
    env "SWIFT_MOJO_REPOSITORY_ROOT=$PRODUCTION_ROOT"
    swift build
    --package-path "$ACCEPTANCE_ROOT"
    --product runtime-worker-acceptance
    --configuration release
    --scratch-path "$VERIFIED_BUILD_ROOT"
    --disable-sandbox
    --force-resolved-versions
)
phase_started_seconds=$SECONDS
run_bounded "$timeout_seconds" "${runner_build_args[@]}"
printf 'runtime-worker-acceptance phase=execution-runner-build seconds=%d\n' \
    "$((SECONDS - phase_started_seconds))" >&2
runner_bin_dir="$(run_bounded "$timeout_seconds" env \
    "SWIFT_MOJO_REPOSITORY_ROOT=$PRODUCTION_ROOT" swift build \
    --package-path "$ACCEPTANCE_ROOT" \
    --configuration release \
    --scratch-path "$VERIFIED_BUILD_ROOT" \
    --disable-sandbox \
    --force-resolved-versions \
    --show-bin-path)"
runner="$runner_bin_dir/runtime-worker-acceptance"
if [[ ! -x "$runner" ]]; then
    echo "runtime-worker acceptance runner was not produced: $runner" >&2
    exit 1
fi
readonly VERIFIED_BIN_DIR="$runner_bin_dir"
execution_runner_source_digest="$(run_bounded "$timeout_seconds" "$runner" \
    --source-digest-at "$REPOSITORY_ROOT")"
if [[ "$execution_runner_source_digest" != "$ACCEPTANCE_SOURCE_DIGEST" ]]; then
    echo "execution runner does not match the verified source snapshot" >&2
    exit 1
fi

swift_build_args=(
    swift build
    --package-path "$PRODUCTION_ROOT"
    --product swift-mojo
    --configuration release
    --scratch-path "$VERIFIED_BUILD_ROOT"
    --disable-sandbox
    --force-resolved-versions
)
phase_started_seconds=$SECONDS
run_bounded "$timeout_seconds" "${swift_build_args[@]}"
printf 'runtime-worker-acceptance phase=authoring-cli-build seconds=%d\n' \
    "$((SECONDS - phase_started_seconds))" >&2
swift_bin_dir="$(run_bounded "$timeout_seconds" swift build \
    --package-path "$PRODUCTION_ROOT" \
    --configuration release \
    --scratch-path "$VERIFIED_BUILD_ROOT" \
    --disable-sandbox \
    --force-resolved-versions \
    --show-bin-path)"
swift_mojo="$swift_bin_dir/swift-mojo"
if [[ "$swift_bin_dir" != "$VERIFIED_BIN_DIR" ]]; then
    echo "verified builds did not share one product directory" >&2
    exit 1
fi
if [[ ! -x "$swift_mojo" ]]; then
    echo "swift-mojo executable was not produced: $swift_mojo" >&2
    exit 1
fi

bundle_dir="$work_dir/RuntimeWorker.bundle"
authoring_environment=(
    env
    "MODULAR_HOME=$MODULAR_HOME"
    "SWIFT_MOJO_EXECUTABLE=$SWIFT_MOJO_EXECUTABLE"
    "SWIFT_MOJO_REPOSITORY_ROOT=$PRODUCTION_ROOT"
)
if [[ -n "${SWIFT_MOJO_LLVM_AR:-}" ]]; then
    authoring_environment+=("SWIFT_MOJO_LLVM_AR=$SWIFT_MOJO_LLVM_AR")
fi

prepare_args=(
    "$swift_mojo" runtime-worker-prepare
    --package-root "$MODEL_ROOT"
    --target RuntimeWorkerAcceptanceModel
    --source-root "$MODEL_ROOT"
    --source "$BINDINGS_SOURCE"
    --output "$bundle_dir"
    --executable-name runtime-worker-acceptance
    --maximum-frame-payload-bytes "$maximum_frame_payload_bytes"
    --target-triple "$target_triple"
    --target-cpu "$target_cpu"
    --target-accelerator "$target_accelerator"
)
for library in "${runtime_libraries[@]}"; do
    prepare_args+=(--runtime-library "$library")
done
if ((${#system_libraries[@]} > 0)); then
    for library in "${system_libraries[@]}"; do
        prepare_args+=(--system-library "$library")
    done
fi
prepare_args+=(--format json)
phase_started_seconds=$SECONDS
run_bounded "$timeout_seconds" "${authoring_environment[@]}" "${prepare_args[@]}"
printf 'runtime-worker-acceptance phase=worker-authoring seconds=%d\n' \
    "$((SECONDS - phase_started_seconds))" >&2

clean_environment=(env -i "PATH=${PATH:-/usr/bin:/bin}" "HOME=${HOME:-/tmp}")
run_bounded "$timeout_seconds" "${clean_environment[@]}" "$swift_mojo" \
    runtime-worker-verify --bundle "$bundle_dir" --format json

relocation_root="$work_dir/relocated"
relocated_bundle="$relocation_root/RuntimeWorker.bundle"
mkdir -p "$relocation_root"
cp -a "$bundle_dir" "$relocated_bundle"
run_bounded "$timeout_seconds" "${clean_environment[@]}" "$swift_mojo" \
    runtime-worker-verify --bundle "$relocated_bundle" --format json

consumer_build_args=(
    env "SWIFT_MOJO_REPOSITORY_ROOT=$PRODUCTION_ROOT"
    swift build
    --package-path "$CONSUMER_ROOT"
    --product RuntimeWorkerAcceptanceConsumer
    --configuration release
    --scratch-path "$VERIFIED_BUILD_ROOT"
    --disable-sandbox
    --force-resolved-versions
)
phase_started_seconds=$SECONDS
run_bounded "$timeout_seconds" "${consumer_build_args[@]}"
printf 'runtime-worker-acceptance phase=consumer-build seconds=%d\n' \
    "$((SECONDS - phase_started_seconds))" >&2
consumer_bin_dir="$(run_bounded "$timeout_seconds" env \
    "SWIFT_MOJO_REPOSITORY_ROOT=$PRODUCTION_ROOT" swift build \
    --package-path "$CONSUMER_ROOT" \
    --configuration release \
    --scratch-path "$VERIFIED_BUILD_ROOT" \
    --disable-sandbox \
    --force-resolved-versions \
    --show-bin-path)"
consumer="$consumer_bin_dir/RuntimeWorkerAcceptanceConsumer"
if [[ "$consumer_bin_dir" != "$VERIFIED_BIN_DIR" ]]; then
    echo "verified consumer did not share the verified product directory" >&2
    exit 1
fi

execution_tmp="$work_dir/execution-tmp"
execution_home="$work_dir/execution-home"
execution_empty_path="$execution_tmp/empty-bin"
worker_process_prefix="$execution_tmp/swift-mojo-worker-"
mkdir -p "$execution_tmp" "$execution_home" "$execution_empty_path"

phase_started_seconds=$SECONDS
run_bounded "$timeout_seconds" env -i \
    "PATH=$execution_empty_path" \
    "HOME=$execution_home" \
    "TMPDIR=$execution_tmp" \
    "$runner" \
    --bundle "$relocated_bundle" \
    --failure-bundle "$relocated_bundle" \
    --consumer "$consumer" \
    --tmpdir "$execution_tmp" \
    --repository-root "$REPOSITORY_ROOT" \
    --expected-source-digest "$ACCEPTANCE_SOURCE_DIGEST" \
    --swift-mojo-revision "$SWIFT_MOJO_REVISION" \
    --deadline-seconds 45
printf 'runtime-worker-acceptance phase=host-lifecycle seconds=%d\n' \
    "$((SECONDS - phase_started_seconds))" >&2
