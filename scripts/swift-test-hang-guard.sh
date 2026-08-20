#!/bin/zsh

set -euo pipefail

repeats=3
timeout_seconds=30
while (( $# > 0 )); do
    case "$1" in
        --repeats)
            repeats=$2
            shift 2
            ;;
        --timeout|--build-timeout)
            timeout_seconds=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            print -u2 "error: unknown option '$1'"
            exit 64
            ;;
    esac
done

if (( $# == 0 )); then
    print -u2 "error: a guarded command is required after --"
    exit 64
fi
if [[ $repeats != <-> ]] || (( repeats < 1 )); then
    print -u2 "error: repeats must be a positive integer"
    exit 64
fi

root=${0:A:h:h}
artifact_root="$root/.test-artifacts/hang-guard"
lock="$artifact_root/.lock"
mkdir -p "$artifact_root"
if ! mkdir "$lock" 2>/dev/null; then
    print -u2 "error: another hang-guard run is active"
    exit 3
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT INT TERM

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_root="$artifact_root/$timestamp"
mkdir -p "$run_root"

for run in {1..$repeats}; do
    if pgrep -f 'swiftpm-testing-helper' >/dev/null; then
        ps -axo pid,ppid,state,etime,command > "$run_root/run-$run.diag.txt"
        print -u2 "error: stale swiftpm-testing-helper exists before run $run"
        exit 2
    fi

    log="$run_root/run-$run.log"
    set +e
    "$root/scripts/swift-test-timeout.sh" "$timeout_seconds" -- "$@" \
        > "$log" 2>&1
    exit_status=$?
    set -e
    command cat "$log"

    ps -axo pid,ppid,state,etime,command > "$run_root/run-$run.diag.txt"
    if (( exit_status != 0 )); then
        print -u2 "error: guarded run $run failed with status $exit_status"
        exit $exit_status
    fi
    if pgrep -f 'swiftpm-testing-helper' >/dev/null; then
        print -u2 "error: run $run left a stale swiftpm-testing-helper"
        exit 2
    fi
done

print "OK: $repeats guarded run(s) completed without timeout or stale helper"
