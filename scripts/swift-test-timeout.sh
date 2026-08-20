#!/bin/zsh

set -euo pipefail

if (( $# < 2 )); then
    print -u2 "usage: $0 <seconds> [--] <command> [arguments ...]"
    exit 64
fi

timeout_seconds=$1
shift
if [[ ${1:-} == "--" ]]; then
    shift
fi
if (( $# == 0 )); then
    print -u2 "error: a command is required"
    exit 64
fi
if [[ $timeout_seconds != <-> ]] \
    || (( timeout_seconds < 1 || timeout_seconds > 120 )); then
    print -u2 "error: timeout must be an integer from 1 through 120 seconds"
    exit 64
fi

root=${0:A:h:h}
exec "$root/scripts/command-timeout.sh" "$timeout_seconds" -- "$@"
