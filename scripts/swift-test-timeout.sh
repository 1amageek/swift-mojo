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

exec /usr/bin/perl - "$timeout_seconds" "$@" <<'PERL'
use strict;
use warnings;
use POSIX qw(setsid WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG);

my $timeout = shift @ARGV;
my $pid = fork();
die "fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    setsid() or die "setsid failed: $!\n";
    exec { $ARGV[0] } @ARGV;
    die "exec failed: $!\n";
}

my $timed_out = 0;
$SIG{ALRM} = sub {
    $timed_out = 1;
    kill 'TERM', -$pid;
    select undef, undef, undef, 2.0;
    kill 'KILL', -$pid;
};

alarm $timeout;
waitpid($pid, 0);
alarm 0;

if ($timed_out) {
    print STDERR "error: command exceeded ${timeout}s and was terminated\n";
    exit 124;
}
if (WIFEXITED($?)) {
    exit WEXITSTATUS($?);
}
if (WIFSIGNALED($?)) {
    exit 128 + WTERMSIG($?);
}
exit 1;
PERL
