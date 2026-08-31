#!/bin/zsh

set -euo pipefail

if (( $# < 2 )); then
    print -u2 "usage: $0 <seconds> [--] <command> [arguments ...]"
    exit 64
fi

timeout_seconds=$1
shift
if [[ ${1:-} == -- ]]; then
    shift
fi
if (( $# == 0 )); then
    print -u2 "error: a command is required"
    exit 64
fi
if [[ $timeout_seconds != <-> ]] \
    || (( timeout_seconds < 1 || timeout_seconds > 900 )); then
    print -u2 "error: timeout must be an integer from 1 through 900 seconds"
    exit 64
fi

exec /usr/bin/perl - \
    "$timeout_seconds" \
    "${COMMAND_TIMEOUT_TERM_FILE:-}" \
    "${COMMAND_TIMEOUT_INT_FILE:-}" \
    "${COMMAND_TIMEOUT_HUP_FILE:-}" \
    "${COMMAND_TIMEOUT_GATE_LOCK_DIRECTORY:-}" \
    "$@" <<'PERL'
use strict;
use warnings;
use Errno qw(EEXIST EINTR);
use IO::Select;
use POSIX qw(
    setsid sigpending sigprocmask SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK
    WIFEXITED WEXITSTATUS WIFSIGNALED WNOHANG WTERMSIG
);
use Time::HiRes qw(CLOCK_MONOTONIC clock_gettime sleep);

my $timeout = shift @ARGV;
my $term_file = shift @ARGV;
my $int_file = shift @ARGV;
my $hup_file = shift @ARGV;
my $gate_lock_directory = shift @ARGV;
my $termination_reason = '';
my $forwarded_signal = 0;
my $child_reaped = 0;
my $child_status = 0;

sub observe_cancellation_file {
    return 15 if $term_file && -e $term_file;
    return 2 if $int_file && -e $int_file;
    return 1 if $hup_file && -e $hup_file;
    return 0;
}

$SIG{TERM} = sub {
    unless ($termination_reason) {
        $termination_reason = 'signal';
        $forwarded_signal = 15;
    }
};
$SIG{INT} = sub {
    unless ($termination_reason) {
        $termination_reason = 'signal';
        $forwarded_signal = 2;
    }
};
$SIG{HUP} = sub {
    unless ($termination_reason) {
        $termination_reason = 'signal';
        $forwarded_signal = 1;
    }
};

if (my $initial_signal = observe_cancellation_file()) {
    exit 128 + $initial_signal;
}
if (($term_file || $int_file || $hup_file) && !$gate_lock_directory) {
    die "cancellation markers require a gate lock directory\n";
}

pipe(my $ready_reader, my $ready_writer)
    or die "ready pipe failed: $!\n";
pipe(my $release_reader, my $release_writer)
    or die "release pipe failed: $!\n";
my $timeout_deadline = clock_gettime(CLOCK_MONOTONIC) + $timeout;
my $pid = fork();
die "fork failed: $!\n" unless defined $pid;

if ($pid == 0) {
    close $ready_reader;
    close $release_writer;
    $SIG{TERM} = 'DEFAULT';
    $SIG{INT} = 'DEFAULT';
    $SIG{HUP} = 'DEFAULT';
    setsid() or die "setsid failed: $!\n";
    syswrite($ready_writer, 'R', 1) == 1
        or die "ready write failed: $!\n";
    close $ready_writer;
    my $release = '';
    while (length($release) == 0) {
        my $read_count = sysread($release_reader, $release, 1);
        if (defined $read_count) {
            exit 125 if $read_count == 0;
            last;
        }
        next if $! == EINTR;
        die "release read failed: $!\n";
    }
    close $release_reader;
    exit 125 unless $release eq 'G';
    exec { $ARGV[0] } @ARGV;
    die "exec failed: $!\n";
}
close $ready_writer;
close $release_reader;

sub reap_without_waiting {
    my $waited_pid = waitpid($pid, WNOHANG);
    if ($waited_pid == $pid) {
        $child_status = $?;
        $child_reaped = 1;
        return 1;
    }
    if ($waited_pid == -1 && $! != EINTR) {
        die "waitpid failed: $!\n";
    }
    return 0;
}

sub reap_after_kill {
    while (!$child_reaped) {
        my $waited_pid = waitpid($pid, 0);
        if ($waited_pid == $pid) {
            $child_status = $?;
            $child_reaped = 1;
            last;
        }
        next if $waited_pid == -1 && $! == EINTR;
        die "waitpid failed: $!\n";
    }
}

sub update_termination_reason {
    if (!$termination_reason) {
        if (my $cancellation_signal = observe_cancellation_file()) {
            $termination_reason = 'signal';
            $forwarded_signal = $cancellation_signal;
        }
    }
    if (!$termination_reason
        && clock_gettime(CLOCK_MONOTONIC) >= $timeout_deadline) {
        $termination_reason = 'timeout';
    }
}

sub acquire_gate_lock {
    return 1 unless $gate_lock_directory;
    while (1) {
        return 1 if mkdir($gate_lock_directory, 0700);
        next if $! == EINTR;
        die "gate lock creation failed: $!\n" unless $! == EEXIST;
        update_termination_reason();
        return 0 if $termination_reason;
        sleep 0.001;
    }
}

sub observe_pending_signal {
    my $pending = POSIX::SigSet->new();
    sigpending($pending) or die "sigpending failed: $!\n";
    return 15 if $pending->ismember(SIGTERM);
    return 2 if $pending->ismember(SIGINT);
    return 1 if $pending->ismember(SIGHUP);
    return 0;
}

# The child cannot exec until it has created its exact session and the parent
# releases this gate. Cancellation during startup therefore either terminates
# an established session group or an exact unreaped direct child that has not
# been permitted to create descendants.
my $ready_selector = IO::Select->new($ready_reader);
my $session_ready = 0;
my $startup_abort_deadline;
while (!$session_ready && !$child_reaped) {
    update_termination_reason();
    if ($termination_reason && !defined $startup_abort_deadline) {
        $startup_abort_deadline = clock_gettime(CLOCK_MONOTONIC) + 0.5;
    }
    if ($ready_selector->can_read(0.01)) {
        my $ready = '';
        my $read_count = sysread($ready_reader, $ready, 1);
        if (defined $read_count) {
            if ($read_count == 1 && $ready eq 'R') {
                $session_ready = 1;
                last;
            }
            if ($read_count == 0) {
                reap_after_kill();
                last;
            }
            die "invalid child readiness\n";
        }
        next if $! == EINTR;
        die "ready read failed: $!\n";
    }
    if (defined $startup_abort_deadline
        && clock_gettime(CLOCK_MONOTONIC) >= $startup_abort_deadline) {
        close $release_writer;
        kill 'TERM', $pid;
        sleep 0.1;
        kill 'KILL', $pid;
        reap_after_kill();
        last;
    }
}
close $ready_reader;

if (!$child_reaped) {
    my $gate_acquired = acquire_gate_lock();
    if (!$gate_acquired) {
        close $release_writer;
        kill 'TERM', $pid;
        sleep 0.1;
        kill 'KILL', $pid;
        reap_after_kill();
    } else {
        # Gate-lock acquisition is the launch linearization point shared with
        # the cancellation publisher. Signals are masked until the final
        # marker and pending-signal checks plus the one-byte release commit are
        # complete. A later cancellation is ordered after launch and is
        # handled as active-session termination by the main loop.
        my $blocked_signals = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP);
        my $previous_signal_mask = POSIX::SigSet->new();
        sigprocmask(SIG_BLOCK, $blocked_signals, $previous_signal_mask)
            or die "signal block failed: $!\n";
        update_termination_reason();
        if (!$termination_reason) {
            if (my $pending_signal = observe_pending_signal()) {
                $termination_reason = 'signal';
                $forwarded_signal = $pending_signal;
            }
        }
        my $release_failed = 0;
        if (!$termination_reason) {
            my $released = syswrite($release_writer, 'G', 1);
            $release_failed = 1
                if !defined $released || $released != 1;
        }
        if ($gate_lock_directory) {
            rmdir($gate_lock_directory)
                or die "gate lock removal failed: $!\n";
        }
        sigprocmask(SIG_SETMASK, $previous_signal_mask)
            or die "signal restore failed: $!\n";
        close $release_writer;
        if ($release_failed) {
            reap_after_kill();
        }
    }
}

while (!$child_reaped) {
    last if reap_without_waiting();
    update_termination_reason();
    if ($termination_reason) {
        # The WNOHANG observation above proves that the exact child session
        # leader has not been reaped, so its PID/PGID cannot be reused while
        # TERM, grace waiting, and any required KILL are performed.
        kill 'TERM', -$pid;
        my $grace_seconds = $termination_reason eq 'signal' ? 0.5 : 2.0;
        # Do not reap the session leader during grace. Its live or zombie
        # process-table entry prevents PID/PGID reuse until every descendant
        # has received the unconditional KILL below.
        sleep $grace_seconds;
        kill 'KILL', -$pid;
        reap_after_kill();
        last;
    }
    sleep 0.01;
}
$SIG{TERM} = 'IGNORE';
$SIG{INT} = 'IGNORE';
$SIG{HUP} = 'IGNORE';

if ($termination_reason eq 'signal') {
    exit 128 + $forwarded_signal;
}
if ($termination_reason eq 'timeout') {
    print STDERR "error: command exceeded ${timeout}s and was terminated\n";
    exit 124;
}
if (WIFEXITED($child_status)) {
    exit WEXITSTATUS($child_status);
}
if (WIFSIGNALED($child_status)) {
    exit 128 + WTERMSIG($child_status);
}
exit 1;
PERL
