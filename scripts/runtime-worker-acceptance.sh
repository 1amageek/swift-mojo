#!/usr/bin/env bash

set -euo pipefail

# This script authors an ephemeral worker bundle, verifies it, and delegates
# the actual-host lifecycle check to the acceptance controller. It never writes
# a receipt or leaves generated binaries in the repository.

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly ACCEPTANCE_ROOT="$REPOSITORY_ROOT/Acceptance/RuntimeWorker"
readonly MODEL_ROOT="$ACCEPTANCE_ROOT/Fixtures/RuntimeWorkerAcceptanceModel"
readonly CONSUMER_ROOT="$ACCEPTANCE_ROOT/Fixtures/Consumer"
readonly BINDINGS_SOURCE="$MODEL_ROOT/Sources/RuntimeWorkerAcceptanceModel/Bindings.swift"
readonly COMMAND_TIMEOUT="$REPOSITORY_ROOT/scripts/command-timeout.sh"

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
work_root="${TMPDIR:-/tmp}"
work_dir="$(mktemp -d "$work_root/swift-mojo-rt4b.XXXXXX")"
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
        cleanup_worker_processes || cleanup_status=1
    fi
    if ! rm -rf -- "$work_dir"; then
        echo "acceptance work directory cleanup failed: $work_dir" >&2
        cleanup_status=1
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

cleanup_worker_processes() {
    local process_command="/bin/ps"
    if [[ ! -x "$process_command" ]]; then
        process_command="/usr/bin/ps"
    fi
    local kill_command="/bin/kill"
    if [[ ! -x "$kill_command" ]]; then
        kill_command="/usr/bin/kill"
    fi
    if [[ ! -x "$process_command" || ! -x "$kill_command" ]]; then
        echo "acceptance cleanup cannot inspect or signal processes" >&2
        return 1
    fi

    local process_listing
    if ! process_listing="$(run_bounded 5 "$process_command" -axo pid=,pgid=,command=)"; then
        echo "acceptance cleanup could not inspect worker processes" >&2
        return 1
    fi

    local group_ids=""
    local process_id=""
    local process_group_id=""
    local line=""
    while IFS= read -r line; do
        [[ "$line" == *"$worker_process_prefix"* ]] || continue
        read -r process_id process_group_id _ <<< "$line"
        [[ "$process_group_id" =~ ^[1-9][0-9]*$ ]] || continue
        case " $group_ids " in
            *" $process_group_id "*) ;;
            *) group_ids+=" $process_group_id" ;;
        esac
    done <<< "$process_listing"

    [[ -n "$group_ids" ]] || return 0
    worker_process_leak_observed=true
    echo "acceptance cleanup observed leaked worker process group:$group_ids" >&2
    local group_id=""
    for group_id in $group_ids; do
        "$kill_command" -TERM "-$group_id" 2>/dev/null || true
    done

    if run_bounded 2 /bin/sleep 1; then
        :
    fi
    process_listing="$(run_bounded 5 "$process_command" -axo pid=,pgid=,command=)" || {
        echo "acceptance cleanup could not recheck worker processes" >&2
        return 1
    }
    group_ids=""
    while IFS= read -r line; do
        [[ "$line" == *"$worker_process_prefix"* ]] || continue
        read -r process_id process_group_id _ <<< "$line"
        [[ "$process_group_id" =~ ^[1-9][0-9]*$ ]] || continue
        case " $group_ids " in
            *" $process_group_id "*) ;;
            *) group_ids+=" $process_group_id" ;;
        esac
    done <<< "$process_listing"

    if [[ -n "$group_ids" ]]; then
        for group_id in $group_ids; do
            "$kill_command" -KILL "-$group_id" 2>/dev/null || true
        done
        if run_bounded 2 /bin/sleep 1; then
            :
        fi
        process_listing="$(run_bounded 5 "$process_command" -axo pid=,pgid=,command=)" || {
            echo "acceptance cleanup could not verify killed worker processes" >&2
            return 1
        }
        while IFS= read -r line; do
            if [[ "$line" == *"$worker_process_prefix"* ]]; then
                echo "acceptance worker process survived cleanup: $line" >&2
                return 1
            fi
        done <<< "$process_listing"
    fi
}

swift_build_args=(
    swift build
    --package-path "$REPOSITORY_ROOT"
    --product swift-mojo
    --configuration release
    --scratch-path "$work_dir/swift-build"
    --disable-sandbox
)
run_bounded "$timeout_seconds" "${swift_build_args[@]}"
swift_bin_dir="$(run_bounded "$timeout_seconds" swift build \
    --package-path "$REPOSITORY_ROOT" \
    --configuration release \
    --scratch-path "$work_dir/swift-build" \
    --show-bin-path)"
swift_mojo="$swift_bin_dir/swift-mojo"
if [[ ! -x "$swift_mojo" ]]; then
    echo "swift-mojo executable was not produced: $swift_mojo" >&2
    exit 1
fi

bundle_dir="$work_dir/RuntimeWorker.bundle"
authoring_environment=(
    env
    "MODULAR_HOME=$MODULAR_HOME"
    "SWIFT_MOJO_EXECUTABLE=$SWIFT_MOJO_EXECUTABLE"
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
run_bounded "$timeout_seconds" "${authoring_environment[@]}" "${prepare_args[@]}"

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
    swift build
    --package-path "$CONSUMER_ROOT"
    --product RuntimeWorkerAcceptanceConsumer
    --configuration release
    --scratch-path "$work_dir/consumer-build"
    --disable-sandbox
)
run_bounded "$timeout_seconds" "${consumer_build_args[@]}"
consumer_bin_dir="$(run_bounded "$timeout_seconds" swift build \
    --package-path "$CONSUMER_ROOT" \
    --configuration release \
    --scratch-path "$work_dir/consumer-build" \
    --show-bin-path)"
consumer="$consumer_bin_dir/RuntimeWorkerAcceptanceConsumer"

runner_build_args=(
    swift build
    --package-path "$ACCEPTANCE_ROOT"
    --product runtime-worker-acceptance
    --configuration release
    --scratch-path "$work_dir/acceptance-build"
    --disable-sandbox
)
run_bounded "$timeout_seconds" "${runner_build_args[@]}"
runner_bin_dir="$(run_bounded "$timeout_seconds" swift build \
    --package-path "$ACCEPTANCE_ROOT" \
    --configuration release \
    --scratch-path "$work_dir/acceptance-build" \
    --show-bin-path)"
runner="$runner_bin_dir/runtime-worker-acceptance"

execution_tmp="$work_dir/execution-tmp"
execution_home="$work_dir/execution-home"
execution_empty_path="$execution_tmp/empty-bin"
worker_process_prefix="$execution_tmp/swift-mojo-worker-"
mkdir -p "$execution_tmp" "$execution_home" "$execution_empty_path"

run_bounded "$timeout_seconds" env -i \
    "PATH=$execution_empty_path" \
    "HOME=$execution_home" \
    "TMPDIR=$execution_tmp" \
    "$runner" \
    --bundle "$relocated_bundle" \
    --failure-bundle "$relocated_bundle" \
    --consumer "$consumer" \
    --tmpdir "$execution_tmp" \
    --deadline-seconds 45
