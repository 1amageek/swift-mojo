#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMMAND_TIMEOUT="$SCRIPT_DIR/command-timeout.sh"

test_root_candidate="$(
    /usr/bin/mktemp -d "${TMPDIR:-/tmp}/swift-mojo-command-timeout-test.XXXXXX"
)"
readonly TEST_ROOT="$(cd "$test_root_candidate" && pwd)"
unset test_root_candidate
readonly NESTED_CHILD_PID_FILE="$TEST_ROOT/nested-child.pid"
readonly DIRECT_CHILD_PID_FILE="$TEST_ROOT/direct-child.pid"
readonly DESCENDANT_PID_FILE="$TEST_ROOT/descendant.pid"
readonly MARKER_CHILD_PID_FILE="$TEST_ROOT/marker-child.pid"
readonly TERM_MARKER_FILE="$TEST_ROOT/cancel-term"
readonly GATE_LOCK_DIRECTORY="$TEST_ROOT/cancel-gate-lock"
readonly PREEXISTING_SENTINEL_FILE="$TEST_ROOT/preexisting-sentinel"
readonly STARTUP_TERM_MARKER_FILE="$TEST_ROOT/startup-cancel-term"
readonly STARTUP_GATE_LOCK_DIRECTORY="$TEST_ROOT/startup-gate-lock"
readonly STARTUP_SENTINEL_FILE="$TEST_ROOT/startup-sentinel"

cleanup() {
    local previous_status=$?
    trap - EXIT
    if [[ -f "$NESTED_CHILD_PID_FILE" ]]; then
        local child_pid
        child_pid="$(/bin/cat "$NESTED_CHILD_PID_FILE")"
        if [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] \
            && /bin/kill -0 "$child_pid" 2>/dev/null; then
            local child_command
            child_command="$(/bin/ps -p "$child_pid" -o command= 2>/dev/null || true)"
            if [[ "$child_command" == *"$NESTED_CHILD_PID_FILE"* ]]; then
                /bin/kill -KILL -- "-$child_pid" 2>/dev/null \
                    || /bin/kill -KILL "$child_pid" 2>/dev/null \
                    || true
            fi
        fi
    fi
    if [[ -f "$DIRECT_CHILD_PID_FILE" ]]; then
        local cleanup_direct_pid
        cleanup_direct_pid="$(/bin/cat "$DIRECT_CHILD_PID_FILE")"
        if [[ "$cleanup_direct_pid" =~ ^[1-9][0-9]*$ ]] \
            && /bin/kill -0 "$cleanup_direct_pid" 2>/dev/null; then
            /bin/kill -KILL "$cleanup_direct_pid" 2>/dev/null || true
        fi
    fi
    for cleanup_pid_file in \
        "$DESCENDANT_PID_FILE" \
        "$MARKER_CHILD_PID_FILE"; do
        if [[ -f "$cleanup_pid_file" ]]; then
            local cleanup_pid
            cleanup_pid="$(/bin/cat "$cleanup_pid_file")"
            if [[ "$cleanup_pid" =~ ^[1-9][0-9]*$ ]] \
                && /bin/kill -0 "$cleanup_pid" 2>/dev/null; then
                /bin/kill -KILL "$cleanup_pid" 2>/dev/null || true
            fi
        fi
    done
    /bin/rm -rf -- "$TEST_ROOT"
    exit "$previous_status"
}
trap cleanup EXIT

set +e
"$COMMAND_TIMEOUT" 5 -- /bin/sh -c 'exit 7'
normal_status=$?
set -e
if ((normal_status != 7)); then
    echo "normal child status was $normal_status, expected 7" >&2
    exit 1
fi

set +e
"$COMMAND_TIMEOUT" 1 -- /usr/bin/perl -e \
    '$SIG{TERM} = "IGNORE"; sleep 30'
timeout_status=$?
set -e
if ((timeout_status != 124)); then
    echo "timeout status was $timeout_status, expected 124" >&2
    exit 1
fi

set +e
"$COMMAND_TIMEOUT" 1 -- \
    "$COMMAND_TIMEOUT" 30 -- \
    /usr/bin/perl -e '
        use strict;
        use warnings;
        my $path = shift @ARGV;
        open my $handle, ">", $path or die "open $path: $!\n";
        print {$handle} "$$\n" or die "write $path: $!\n";
        close $handle or die "close $path: $!\n";
        $SIG{TERM} = "IGNORE";
        sleep 30;
    ' "$NESTED_CHILD_PID_FILE"
nested_status=$?
set -e
if ((nested_status != 124)); then
    echo "nested timeout status was $nested_status, expected 124" >&2
    exit 1
fi
if [[ ! -f "$NESTED_CHILD_PID_FILE" ]]; then
    echo "nested timeout child did not record its PID" >&2
    exit 1
fi

readonly nested_child_pid="$(/bin/cat "$NESTED_CHILD_PID_FILE")"
if [[ ! "$nested_child_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "nested timeout child PID is invalid: $nested_child_pid" >&2
    exit 1
fi
for _ in 1 2 3 4 5; do
    if ! /bin/kill -0 "$nested_child_pid" 2>/dev/null; then
        break
    fi
    /bin/sleep 1
done
if /bin/kill -0 "$nested_child_pid" 2>/dev/null; then
    echo "nested timeout child survived external termination: $nested_child_pid" >&2
    exit 1
fi

"$COMMAND_TIMEOUT" 30 -- \
    /usr/bin/perl -e '
        use strict;
        use warnings;
        my $path = shift @ARGV;
        open my $handle, ">", $path or die "open $path: $!\n";
        print {$handle} "$$\n" or die "write $path: $!\n";
        close $handle or die "close $path: $!\n";
        $SIG{TERM} = "IGNORE";
        sleep 30;
    ' "$DIRECT_CHILD_PID_FILE" &
readonly direct_supervisor_pid=$!
for _ in 1 2 3 4 5; do
    [[ -f "$DIRECT_CHILD_PID_FILE" ]] && break
    /bin/sleep 1
done
if [[ ! -f "$DIRECT_CHILD_PID_FILE" ]]; then
    echo "directly signalled timeout child did not record its PID" >&2
    exit 1
fi
/bin/kill -TERM "$direct_supervisor_pid"
set +e
wait "$direct_supervisor_pid"
direct_status=$?
set -e
if ((direct_status != 143)); then
    echo "direct signal status was $direct_status, expected 143" >&2
    exit 1
fi
readonly direct_child_pid="$(/bin/cat "$DIRECT_CHILD_PID_FILE")"
if /bin/kill -0 "$direct_child_pid" 2>/dev/null; then
    echo "child survived direct supervisor termination: $direct_child_pid" >&2
    exit 1
fi

set +e
"$COMMAND_TIMEOUT" 1 -- /usr/bin/perl -e '
    use strict;
    use warnings;
    my $path = shift @ARGV;
    my $descendant = fork();
    die "fork: $!\n" unless defined $descendant;
    if ($descendant == 0) {
        $SIG{TERM} = "IGNORE";
        open my $handle, ">", $path or die "open $path: $!\n";
        print {$handle} "$$\n" or die "write $path: $!\n";
        close $handle or die "close $path: $!\n";
        sleep 30;
        exit 0;
    }
    $SIG{TERM} = sub { exit 0 };
    sleep 30;
' "$DESCENDANT_PID_FILE"
descendant_status=$?
set -e
if ((descendant_status != 124)); then
    echo "descendant timeout status was $descendant_status, expected 124" >&2
    exit 1
fi
if [[ ! -f "$DESCENDANT_PID_FILE" ]]; then
    echo "TERM-ignoring descendant did not record its PID" >&2
    exit 1
fi
readonly descendant_pid="$(/bin/cat "$DESCENDANT_PID_FILE")"
for _ in 1 2 3 4 5; do
    if ! /bin/kill -0 "$descendant_pid" 2>/dev/null; then
        break
    fi
    /bin/sleep 1
done
if /bin/kill -0 "$descendant_pid" 2>/dev/null; then
    echo "TERM-ignoring descendant survived leader exit: $descendant_pid" >&2
    exit 1
fi

: > "$TERM_MARKER_FILE"
set +e
COMMAND_TIMEOUT_TERM_FILE="$TERM_MARKER_FILE" \
COMMAND_TIMEOUT_GATE_LOCK_DIRECTORY="$GATE_LOCK_DIRECTORY" \
    "$COMMAND_TIMEOUT" 30 -- /bin/sh -c \
        ': > "$1"' command-timeout-fixture "$PREEXISTING_SENTINEL_FILE"
preexisting_marker_status=$?
set -e
if ((preexisting_marker_status != 143)); then
    echo "preexisting marker status was $preexisting_marker_status, expected 143" >&2
    exit 1
fi
if [[ -e "$PREEXISTING_SENTINEL_FILE" ]]; then
    echo "command executed despite a preexisting cancellation marker" >&2
    exit 1
fi
/bin/rm -f -- "$TERM_MARKER_FILE"

COMMAND_TIMEOUT_TERM_FILE="$TERM_MARKER_FILE" \
COMMAND_TIMEOUT_GATE_LOCK_DIRECTORY="$GATE_LOCK_DIRECTORY" \
    "$COMMAND_TIMEOUT" 30 -- /usr/bin/perl -e '
        use strict;
        use warnings;
        my $path = shift @ARGV;
        open my $handle, ">", $path or die "open $path: $!\n";
        print {$handle} "$$\n" or die "write $path: $!\n";
        close $handle or die "close $path: $!\n";
        $SIG{TERM} = "IGNORE";
        sleep 30;
    ' "$MARKER_CHILD_PID_FILE" &
readonly marker_supervisor_pid=$!
for _ in 1 2 3 4 5; do
    [[ -f "$MARKER_CHILD_PID_FILE" ]] && break
    /bin/sleep 1
done
if [[ ! -f "$MARKER_CHILD_PID_FILE" ]]; then
    echo "marker-cancelled child did not record its PID" >&2
    exit 1
fi
: > "$TERM_MARKER_FILE"
set +e
wait "$marker_supervisor_pid"
marker_status=$?
set -e
if ((marker_status != 143)); then
    echo "marker cancellation status was $marker_status, expected 143" >&2
    exit 1
fi
readonly marker_child_pid="$(/bin/cat "$MARKER_CHILD_PID_FILE")"
if /bin/kill -0 "$marker_child_pid" 2>/dev/null; then
    echo "child survived cancellation marker termination: $marker_child_pid" >&2
    exit 1
fi

/bin/mkdir "$STARTUP_GATE_LOCK_DIRECTORY"
COMMAND_TIMEOUT_TERM_FILE="$STARTUP_TERM_MARKER_FILE" \
COMMAND_TIMEOUT_GATE_LOCK_DIRECTORY="$STARTUP_GATE_LOCK_DIRECTORY" \
    "$COMMAND_TIMEOUT" 30 -- /bin/sh -c \
        ': > "$1"' command-timeout-fixture "$STARTUP_SENTINEL_FILE" &
readonly startup_supervisor_pid=$!
/bin/sleep 1
: > "$STARTUP_TERM_MARKER_FILE"
/bin/rmdir "$STARTUP_GATE_LOCK_DIRECTORY"
set +e
wait "$startup_supervisor_pid"
startup_status=$?
set -e
if ((startup_status != 143)); then
    echo "startup gate cancellation status was $startup_status, expected 143" >&2
    exit 1
fi
if [[ -e "$STARTUP_SENTINEL_FILE" ]]; then
    echo "startup gate released a command after cancellation won the gate" >&2
    exit 1
fi

echo "command-timeout normal, timeout, nested, descendant, direct, marker, and startup-gate paths passed"
