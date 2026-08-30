#define _GNU_SOURCE 1

#include "CMojoPOSIXSupport.h"

#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(__linux__) && defined(__GLIBC__)
#include <dirent.h>
#include <stdio.h>
#endif

#if defined(__APPLE__) || defined(__GLIBC__)
#define SWIFT_MOJO_HAS_POSIX 1
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#else
#define SWIFT_MOJO_HAS_POSIX 0
#endif

#if defined(__GLIBC__) && defined(__GLIBC_PREREQ)
#if __GLIBC_PREREQ(2, 34)
#define SWIFT_MOJO_HAS_SPAWN_CLOSEFROM 1
#else
#define SWIFT_MOJO_HAS_SPAWN_CLOSEFROM 0
#endif
#else
#define SWIFT_MOJO_HAS_SPAWN_CLOSEFROM 0
#endif

#if SWIFT_MOJO_HAS_POSIX && defined(POSIX_SPAWN_SETSID)
#if defined(__GLIBC__)
#if SWIFT_MOJO_HAS_SPAWN_CLOSEFROM
#define SWIFT_MOJO_HAS_WORKER_POSIX 1
#else
#define SWIFT_MOJO_HAS_WORKER_POSIX 0
#endif
#elif defined(__APPLE__) && defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
#define SWIFT_MOJO_HAS_WORKER_POSIX 1
#else
#define SWIFT_MOJO_HAS_WORKER_POSIX 0
#endif
#else
#define SWIFT_MOJO_HAS_WORKER_POSIX 0
#endif

#define SWIFT_MOJO_WORKER_PROTOCOL_DESCRIPTOR 3
#define SWIFT_MOJO_WORKER_MIN_DESCRIPTOR 4

static void set_error(int32_t *error_code, int32_t value) {
    if (error_code != NULL) {
        *error_code = value;
    }
}

#if SWIFT_MOJO_HAS_POSIX
static void close_descriptor_if_valid(int *descriptor) {
    if (descriptor != NULL && *descriptor >= 0) {
        (void)close(*descriptor);
        *descriptor = -1;
    }
}

static int duplicate_descriptor_at_or_above_four(int descriptor) {
    int duplicate;
#if defined(F_DUPFD_CLOEXEC)
    duplicate = fcntl(
        descriptor,
        F_DUPFD_CLOEXEC,
        SWIFT_MOJO_WORKER_MIN_DESCRIPTOR
    );
    if (duplicate >= 0) {
        return duplicate;
    }
    if (errno != EINVAL && errno != ENOTSUP) {
        return -1;
    }
#endif

    duplicate = fcntl(
        descriptor,
        F_DUPFD,
        SWIFT_MOJO_WORKER_MIN_DESCRIPTOR
    );
    if (duplicate < 0) {
        return -1;
    }
    int flags = fcntl(duplicate, F_GETFD);
    if (flags < 0 || fcntl(duplicate, F_SETFD, flags | FD_CLOEXEC) != 0) {
        int saved_error = errno;
        (void)close(duplicate);
        errno = saved_error;
        return -1;
    }
    return duplicate;
}

static int normalize_descriptor(int *descriptor) {
    int original = *descriptor;
    int duplicate = duplicate_descriptor_at_or_above_four(original);
    if (duplicate < 0) {
        return -1;
    }
    // Ownership of the original descriptor ends at this exactly-once close
    // attempt. A failed close may already have released and reused the number,
    // so failure cleanup must never try that descriptor again.
    *descriptor = -1;
    if (close(original) != 0) {
        int saved_error = errno;
        (void)close(duplicate);
        errno = saved_error;
        return -1;
    }
    *descriptor = duplicate;
    return 0;
}

static int set_nonblocking(int descriptor) {
    int flags = fcntl(descriptor, F_GETFL);
    if (flags < 0) {
        return -1;
    }
    if ((flags & O_NONBLOCK) != 0) {
        return 0;
    }
    return fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
}

static int set_socket_no_sigpipe(int descriptor) {
#if defined(SO_NOSIGPIPE)
    int enabled = 1;
    if (setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            (socklen_t)sizeof(enabled)
        ) != 0) {
        return -1;
    }
#else
    (void)descriptor;
#endif
    return 0;
}

static int create_normalized_socketpair(int descriptors[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, descriptors) != 0) {
        return -1;
    }
    if (normalize_descriptor(&descriptors[0]) != 0
        || normalize_descriptor(&descriptors[1]) != 0) {
        int saved_error = errno;
        close_descriptor_if_valid(&descriptors[0]);
        close_descriptor_if_valid(&descriptors[1]);
        errno = saved_error;
        return -1;
    }
    if (set_nonblocking(descriptors[0]) != 0
        || set_socket_no_sigpipe(descriptors[0]) != 0) {
        int saved_error = errno;
        close_descriptor_if_valid(&descriptors[0]);
        close_descriptor_if_valid(&descriptors[1]);
        errno = saved_error;
        return -1;
    }
    return 0;
}

static int create_normalized_pipe(
    int descriptors[2],
    int nonblocking_read,
    int nonblocking_write
) {
    if (pipe(descriptors) != 0) {
        return -1;
    }
    if (normalize_descriptor(&descriptors[0]) != 0
        || normalize_descriptor(&descriptors[1]) != 0) {
        int saved_error = errno;
        close_descriptor_if_valid(&descriptors[0]);
        close_descriptor_if_valid(&descriptors[1]);
        errno = saved_error;
        return -1;
    }
    if ((nonblocking_read != 0 && set_nonblocking(descriptors[0]) != 0)
        || (nonblocking_write != 0 && set_nonblocking(descriptors[1]) != 0)) {
        int saved_error = errno;
        close_descriptor_if_valid(&descriptors[0]);
        close_descriptor_if_valid(&descriptors[1]);
        errno = saved_error;
        return -1;
    }
    return 0;
}
#endif

#if defined(__linux__) && defined(__GLIBC__)
static int process_stat(
    int32_t process_id,
    int32_t *process_group,
    char *state
) {
    char path[64];
    int length = snprintf(
        path,
        sizeof(path),
        "/proc/%d/stat",
        (int)process_id
    );
    if (length <= 0 || (size_t)length >= sizeof(path)) {
        return -1;
    }
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        return -1;
    }
    char record[4096];
    char *read_result = fgets(record, sizeof(record), file);
    (void)fclose(file);
    if (read_result == NULL) {
        return -1;
    }
    char *command_end = strrchr(record, ')');
    if (command_end == NULL) {
        return -1;
    }
    int parent = 0;
    int group = 0;
    char observed_state = 0;
    if (sscanf(command_end + 1, " %c %d %d", &observed_state, &parent, &group)
        != 3) {
        return -1;
    }
    *process_group = (int32_t)group;
    *state = observed_state;
    return 0;
}

static int process_state_is_live(char state) {
    return state != 'Z' && state != 'X' && state != 'x';
}

static int32_t linux_process_group_has_live_member(int32_t process_group) {
    DIR *directory = opendir("/proc");
    if (directory == NULL) {
        return -1;
    }
    struct dirent *entry;
    while ((entry = readdir(directory)) != NULL) {
        char *end = NULL;
        long candidate = strtol(entry->d_name, &end, 10);
        if (end == entry->d_name || *end != '\0' || candidate <= 0
            || candidate > INT32_MAX) {
            continue;
        }
        int32_t observed_group = 0;
        char state = 0;
        if (process_stat((int32_t)candidate, &observed_group, &state) == 0
            && observed_group == process_group
            && process_state_is_live(state)) {
            (void)closedir(directory);
            return 1;
        }
    }
    (void)closedir(directory);
    return 0;
}
#endif

int32_t swift_mojo_posix_platform_supported(void) {
#if SWIFT_MOJO_HAS_POSIX
#if defined(__GLIBC__)
#if !defined(__GLIBC_PREREQ)
    return 0;
#elif !__GLIBC_PREREQ(2, 34)
    return 0;
#endif
#endif
    return 1;
#else
    return 0;
#endif
}

int32_t swift_mojo_posix_worker_platform_supported(void) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    return 1;
#else
    return 0;
#endif
}

int32_t swift_mojo_posix_open_file(
    const char *path,
    int32_t truncate,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    int flags = O_CREAT | O_RDWR | O_CLOEXEC;
    if (truncate != 0) {
        flags |= O_TRUNC;
    }
    int descriptor = open(path, flags, 0600);
    if (descriptor < 0) {
        set_error(error_code, errno);
        return -1;
    }
    return (int32_t)descriptor;
#else
    (void)path;
    (void)truncate;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_close_file(
    int32_t descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    if (close((int)descriptor) != 0) {
        set_error(error_code, errno);
        return -1;
    }
    return 0;
#else
    (void)descriptor;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

static int32_t lock_file(
    int32_t descriptor,
    int operation,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    int result;
    do {
        result = flock((int)descriptor, operation);
    } while (result != 0 && errno == EINTR);
    if (result != 0) {
        set_error(error_code, errno);
        return -1;
    }
    return 0;
#else
    (void)descriptor;
    (void)operation;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_lock_exclusive(
    int32_t descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    return lock_file(descriptor, LOCK_EX, error_code);
#else
    return lock_file(descriptor, 0, error_code);
#endif
}

int32_t swift_mojo_posix_try_lock_exclusive(
    int32_t descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    int result;
    do {
        result = flock((int)descriptor, LOCK_EX | LOCK_NB);
    } while (result != 0 && errno == EINTR);
    if (result == 0) {
        return 1;
    }
    if (errno == EWOULDBLOCK || errno == EAGAIN) {
        return 0;
    }
    set_error(error_code, errno);
    return -1;
#else
    (void)descriptor;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_unlock(
    int32_t descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    return lock_file(descriptor, LOCK_UN, error_code);
#else
    return lock_file(descriptor, 0, error_code);
#endif
}

int32_t swift_mojo_posix_spawn(
    const char *executable,
    char *const arguments[],
    char *const environment[],
    int32_t output_descriptor,
    int32_t *process_id,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    if (swift_mojo_posix_platform_supported() == 0) {
        set_error(error_code, ENOTSUP);
        return SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        set_error(error_code, result);
        return SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED;
    }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        set_error(error_code, result);
        return SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED;
    }

    result = posix_spawn_file_actions_adddup2(
        &actions,
        (int)output_descriptor,
        STDOUT_FILENO
    );
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(
            &actions,
            (int)output_descriptor,
            STDERR_FILENO
        );
    }
    if (result == 0
        && output_descriptor != STDOUT_FILENO
        && output_descriptor != STDERR_FILENO) {
        result = posix_spawn_file_actions_addclose(
            &actions,
            (int)output_descriptor
        );
    }
#if defined(__GLIBC__)
#if SWIFT_MOJO_HAS_SPAWN_CLOSEFROM
    if (result == 0) {
        result = posix_spawn_file_actions_addclosefrom_np(&actions, 3);
    }
#else
    if (result == 0) {
        result = ENOTSUP;
    }
#endif
#endif

    short flags = 0;
#if defined(POSIX_SPAWN_SETSID)
    flags |= POSIX_SPAWN_SETSID;
#else
    result = ENOTSUP;
#endif
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (result == 0) {
        result = posix_spawnattr_setflags(&attributes, flags);
    }

    pid_t child = 0;
    int spawn_attempted = 0;
    if (result == 0) {
        spawn_attempted = 1;
        if (environment != NULL) {
            result = posix_spawn(
                &child,
                executable,
                &actions,
                &attributes,
                arguments,
                environment
            );
        } else {
            extern char **environ;
            result = posix_spawn(
                &child,
                executable,
                &actions,
                &attributes,
                arguments,
                environ
            );
        }
    }

    // The initialized action objects contain no live process ownership. Their
    // destroy status must not turn a successful spawn into a failure that
    // loses the child PID.
    (void)posix_spawnattr_destroy(&attributes);
    (void)posix_spawn_file_actions_destroy(&actions);

    if (result != 0) {
        set_error(error_code, result);
        return spawn_attempted
            ? SWIFT_MOJO_POSIX_SPAWN_LAUNCH_FAILED
            : SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED;
    }
    *process_id = (int32_t)child;
    return SWIFT_MOJO_POSIX_SPAWN_SUCCEEDED;
#else
    (void)executable;
    (void)arguments;
    (void)environment;
    (void)output_descriptor;
    (void)process_id;
    set_error(error_code, ENOTSUP);
    return SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED;
#endif
}

int32_t swift_mojo_posix_worker_spawn(
    const char *executable,
    char *const arguments[],
    char *const environment[],
    int32_t *protocol_descriptor,
    int32_t *diagnostic_descriptor,
    int32_t *process_id,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    if (executable == NULL
        || arguments == NULL
        || arguments[0] == NULL
        || protocol_descriptor == NULL
        || diagnostic_descriptor == NULL
        || process_id == NULL) {
        set_error(error_code, EINVAL);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }
    *protocol_descriptor = -1;
    *diagnostic_descriptor = -1;
    *process_id = 0;

    int protocol[2] = {-1, -1};
    int diagnostics[2] = {-1, -1};
    if (create_normalized_socketpair(protocol) != 0) {
        set_error(error_code, errno);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }
    if (create_normalized_pipe(diagnostics, 1, 0) != 0) {
        int saved_error = errno;
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        set_error(error_code, saved_error);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }

    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) {
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        close_descriptor_if_valid(&diagnostics[0]);
        close_descriptor_if_valid(&diagnostics[1]);
        set_error(error_code, result);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        (void)posix_spawn_file_actions_destroy(&actions);
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        close_descriptor_if_valid(&diagnostics[0]);
        close_descriptor_if_valid(&diagnostics[1]);
        set_error(error_code, result);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }

    result = posix_spawn_file_actions_addopen(
        &actions,
        STDIN_FILENO,
        "/dev/null",
        O_RDONLY,
        0
    );
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(
            &actions,
            protocol[1],
            SWIFT_MOJO_WORKER_PROTOCOL_DESCRIPTOR
        );
    }
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(
            &actions,
            diagnostics[1],
            STDOUT_FILENO
        );
    }
    if (result == 0) {
        result = posix_spawn_file_actions_adddup2(
            &actions,
            diagnostics[1],
            STDERR_FILENO
        );
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addclose(&actions, protocol[0]);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addclose(&actions, protocol[1]);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addclose(&actions, diagnostics[0]);
    }
    if (result == 0) {
        result = posix_spawn_file_actions_addclose(&actions, diagnostics[1]);
    }
#if defined(__GLIBC__)
#if SWIFT_MOJO_HAS_SPAWN_CLOSEFROM
    if (result == 0) {
        result = posix_spawn_file_actions_addclosefrom_np(
            &actions,
            SWIFT_MOJO_WORKER_MIN_DESCRIPTOR
        );
    }
#else
    if (result == 0) {
        result = ENOTSUP;
    }
#endif
#endif

    short flags = 0;
#if defined(POSIX_SPAWN_SETSID)
    flags |= POSIX_SPAWN_SETSID;
#else
    result = ENOTSUP;
#endif
#if defined(POSIX_SPAWN_CLOEXEC_DEFAULT)
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if (result == 0) {
        result = posix_spawnattr_setflags(&attributes, flags);
    }

    pid_t child = 0;
    int spawn_attempted = 0;
    if (result == 0) {
        spawn_attempted = 1;
        if (environment != NULL) {
            result = posix_spawn(
                &child,
                executable,
                &actions,
                &attributes,
                arguments,
                environment
            );
        } else {
            extern char **environ;
            result = posix_spawn(
                &child,
                executable,
                &actions,
                &attributes,
                arguments,
                environ
            );
        }
    }

    // Setup objects borrow descriptors and never own the child process.
    (void)posix_spawnattr_destroy(&attributes);
    (void)posix_spawn_file_actions_destroy(&actions);

    if (result != 0) {
        int saved_error = result;
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        close_descriptor_if_valid(&diagnostics[0]);
        close_descriptor_if_valid(&diagnostics[1]);
        set_error(error_code, saved_error);
        return spawn_attempted
            ? SWIFT_MOJO_POSIX_WORKER_SPAWN_LAUNCH_FAILED
            : SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }
    if ((int64_t)child <= 0) {
        int saved_error = ECHILD;
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        close_descriptor_if_valid(&diagnostics[0]);
        close_descriptor_if_valid(&diagnostics[1]);
        set_error(error_code, saved_error);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }
    if ((int64_t)child > INT32_MAX) {
        int saved_error = EOVERFLOW;
        (void)kill(-child, SIGKILL);
        int status = 0;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        close_descriptor_if_valid(&protocol[0]);
        close_descriptor_if_valid(&protocol[1]);
        close_descriptor_if_valid(&diagnostics[0]);
        close_descriptor_if_valid(&diagnostics[1]);
        set_error(error_code, saved_error);
        return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
    }

    // The child owns the protocol and diagnostic write endpoints after spawn.
    // Each close is attempted once; the descriptor state is never retried.
    (void)close(protocol[1]);
    protocol[1] = -1;
    (void)close(diagnostics[1]);
    diagnostics[1] = -1;
    *protocol_descriptor = (int32_t)protocol[0];
    *diagnostic_descriptor = (int32_t)diagnostics[0];
    *process_id = (int32_t)child;
    return SWIFT_MOJO_POSIX_WORKER_SPAWN_SUCCEEDED;
#else
    (void)executable;
    (void)arguments;
    (void)environment;
    (void)protocol_descriptor;
    (void)diagnostic_descriptor;
    (void)process_id;
    set_error(error_code, ENOTSUP);
    return SWIFT_MOJO_POSIX_WORKER_SPAWN_SETUP_FAILED;
#endif
}

int32_t swift_mojo_posix_worker_create_wakeup(
    int32_t *read_descriptor,
    int32_t *write_descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    if (read_descriptor == NULL || write_descriptor == NULL) {
        set_error(error_code, EINVAL);
        return -1;
    }
    int descriptors[2] = {-1, -1};
    if (create_normalized_socketpair(descriptors) != 0) {
        set_error(error_code, errno);
        return -1;
    }
    if (set_nonblocking(descriptors[1]) != 0
        || set_socket_no_sigpipe(descriptors[1]) != 0) {
        int saved_error = errno;
        close_descriptor_if_valid(&descriptors[0]);
        close_descriptor_if_valid(&descriptors[1]);
        set_error(error_code, saved_error);
        return -1;
    }
    *read_descriptor = (int32_t)descriptors[0];
    *write_descriptor = (int32_t)descriptors[1];
    return 0;
#else
    (void)read_descriptor;
    (void)write_descriptor;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_worker_signal_wakeup(
    int32_t write_descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    const uint8_t token = 1;
    int flags = 0;
#if defined(MSG_NOSIGNAL)
    flags |= MSG_NOSIGNAL;
#endif
    ssize_t result = send(
        (int)write_descriptor,
        &token,
        sizeof(token),
        flags
    );
    if (result == (ssize_t)sizeof(token) || (result < 0
        && (errno == EAGAIN || errno == EWOULDBLOCK))) {
        return 0;
    }
    if (result < 0) {
        set_error(error_code, errno);
    } else {
        set_error(error_code, EIO);
    }
    return -1;
#else
    (void)write_descriptor;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

#if SWIFT_MOJO_HAS_WORKER_POSIX
static int32_t worker_poll_events(
    short revents,
    int32_t readable_event,
    int32_t writable_event,
    int32_t hangup_event,
    int32_t error_event
) {
    int32_t events = 0;
    if ((revents & (POLLIN | POLLPRI)) != 0) {
        events |= readable_event;
    }
    if ((revents & POLLOUT) != 0) {
        events |= writable_event;
    }
    if ((revents & POLLHUP) != 0) {
        events |= hangup_event;
    }
    if ((revents & POLLERR) != 0) {
        events |= error_event;
    }
    return events;
}
#endif

int32_t swift_mojo_posix_worker_poll(
    int32_t protocol_descriptor,
    int32_t diagnostic_descriptor,
    int32_t wakeup_descriptor,
    int32_t interests,
    int32_t timeout_milliseconds,
    int32_t *event_mask,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    if (event_mask == NULL || timeout_milliseconds < 0
        || (interests & ~(SWIFT_MOJO_POSIX_WORKER_INTEREST_READ
            | SWIFT_MOJO_POSIX_WORKER_INTEREST_WRITE)) != 0) {
        set_error(error_code, EINVAL);
        return -1;
    }
    struct pollfd descriptors[3];
    int descriptor_count = 0;
    int protocol_index = -1;
    int diagnostic_index = -1;
    int wakeup_index = -1;
    if (protocol_descriptor >= 0) {
        protocol_index = descriptor_count++;
        descriptors[protocol_index].fd = (int)protocol_descriptor;
        descriptors[protocol_index].events = POLLERR | POLLHUP;
        if ((interests & SWIFT_MOJO_POSIX_WORKER_INTEREST_READ) != 0) {
            descriptors[protocol_index].events |= POLLIN;
        }
        if ((interests & SWIFT_MOJO_POSIX_WORKER_INTEREST_WRITE) != 0) {
            descriptors[protocol_index].events |= POLLOUT;
        }
        descriptors[protocol_index].revents = 0;
    }
    if (diagnostic_descriptor >= 0) {
        diagnostic_index = descriptor_count++;
        descriptors[diagnostic_index].fd = (int)diagnostic_descriptor;
        descriptors[diagnostic_index].events = POLLIN | POLLERR | POLLHUP;
        descriptors[diagnostic_index].revents = 0;
    }
    if (wakeup_descriptor >= 0) {
        wakeup_index = descriptor_count++;
        descriptors[wakeup_index].fd = (int)wakeup_descriptor;
        descriptors[wakeup_index].events = POLLIN | POLLERR | POLLHUP;
        descriptors[wakeup_index].revents = 0;
    }
    if (descriptor_count == 0) {
        set_error(error_code, EINVAL);
        return -1;
    }

    int result = poll(descriptors, (nfds_t)descriptor_count, timeout_milliseconds);
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    if (result == 0) {
        *event_mask = 0;
        return 0;
    }
    for (int index = 0; index < descriptor_count; index += 1) {
        if ((descriptors[index].revents & POLLNVAL) != 0) {
            set_error(error_code, EBADF);
            return -1;
        }
    }

    int32_t events = 0;
    if (protocol_index >= 0) {
        events |= worker_poll_events(
            descriptors[protocol_index].revents,
            SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_READABLE,
            SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_WRITABLE,
            SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_HANGUP,
            SWIFT_MOJO_POSIX_WORKER_EVENT_PROTOCOL_ERROR
        );
    }
    if (diagnostic_index >= 0) {
        events |= worker_poll_events(
            descriptors[diagnostic_index].revents,
            SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_READABLE,
            0,
            SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_HANGUP,
            SWIFT_MOJO_POSIX_WORKER_EVENT_DIAGNOSTIC_ERROR
        );
    }
    if (wakeup_index >= 0) {
        events |= worker_poll_events(
            descriptors[wakeup_index].revents,
            SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_READABLE,
            0,
            SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_HANGUP,
            SWIFT_MOJO_POSIX_WORKER_EVENT_WAKEUP_ERROR
        );
    }
    *event_mask = events;
    return 1;
#else
    (void)protocol_descriptor;
    (void)diagnostic_descriptor;
    (void)wakeup_descriptor;
    (void)interests;
    (void)timeout_milliseconds;
    (void)event_mask;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int64_t swift_mojo_posix_worker_read(
    int32_t descriptor,
    void *buffer,
    int64_t count,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    if (count <= 0 || buffer == NULL || (uint64_t)count > SIZE_MAX) {
        set_error(error_code, EINVAL);
        return -1;
    }
    ssize_t result = read((int)descriptor, buffer, (size_t)count);
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    return (int64_t)result;
#else
    (void)descriptor;
    (void)buffer;
    (void)count;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int64_t swift_mojo_posix_worker_write(
    int32_t descriptor,
    const void *buffer,
    int64_t count,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_WORKER_POSIX
    if (count <= 0 || buffer == NULL || (uint64_t)count > SIZE_MAX) {
        set_error(error_code, EINVAL);
        return -1;
    }
    int flags = 0;
#if defined(MSG_NOSIGNAL)
    flags |= MSG_NOSIGNAL;
#endif
    ssize_t result = send(
        (int)descriptor,
        buffer,
        (size_t)count,
        flags
    );
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    return (int64_t)result;
#else
    (void)descriptor;
    (void)buffer;
    (void)count;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_wait_nohang(
    int32_t process_id,
    int32_t *wait_status,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    int status = 0;
    pid_t result;
    do {
        result = waitpid((pid_t)process_id, &status, WNOHANG);
    } while (result < 0 && errno == EINTR);
    if (result == 0) {
        return 0;
    }
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    *wait_status = (int32_t)status;
    return 1;
#else
    (void)process_id;
    (void)wait_status;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_signal_group(
    int32_t process_id,
    int32_t signal_number,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    if (kill(-(pid_t)process_id, (int)signal_number) != 0
        && errno != ESRCH) {
        set_error(error_code, errno);
        return -1;
    }
    return 0;
#else
    (void)process_id;
    (void)signal_number;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_process_group_alive(int32_t process_id) {
#if SWIFT_MOJO_HAS_POSIX
    errno = 0;
    int exists = kill(-(pid_t)process_id, 0) == 0 || errno == EPERM;
    if (!exists) {
        return 0;
    }
#if defined(__linux__) && defined(__GLIBC__)
    int32_t live_member = linux_process_group_has_live_member(process_id);
    if (live_member >= 0) {
        return live_member;
    }
#endif
    return 1;
#else
    (void)process_id;
    return 0;
#endif
}

int32_t swift_mojo_posix_process_alive(int32_t process_id) {
#if SWIFT_MOJO_HAS_POSIX
    errno = 0;
    int exists = kill((pid_t)process_id, 0) == 0 || errno == EPERM;
    if (!exists) {
        return 0;
    }
#if defined(__linux__) && defined(__GLIBC__)
    int32_t process_group = 0;
    char state = 0;
    if (process_stat(process_id, &process_group, &state) == 0) {
        return process_state_is_live(state);
    }
#endif
    return 1;
#else
    (void)process_id;
    return 0;
#endif
}

int64_t swift_mojo_posix_seek_start(
    int32_t descriptor,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    off_t result = lseek((int)descriptor, 0, SEEK_SET);
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    return (int64_t)result;
#else
    (void)descriptor;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int64_t swift_mojo_posix_read(
    int32_t descriptor,
    void *buffer,
    int64_t count,
    int32_t *error_code
) {
#if SWIFT_MOJO_HAS_POSIX
    ssize_t result;
    do {
        result = read((int)descriptor, buffer, (size_t)count);
    } while (result < 0 && errno == EINTR);
    if (result < 0) {
        set_error(error_code, errno);
        return -1;
    }
    return (int64_t)result;
#else
    (void)descriptor;
    (void)buffer;
    (void)count;
    set_error(error_code, ENOTSUP);
    return -1;
#endif
}

int32_t swift_mojo_posix_error_is_no_child(int32_t error_code) {
#if SWIFT_MOJO_HAS_POSIX
    return error_code == ECHILD;
#else
    (void)error_code;
    return 0;
#endif
}

int32_t swift_mojo_posix_error_is_interrupted(int32_t error_code) {
#if SWIFT_MOJO_HAS_POSIX
    return error_code == EINTR;
#else
    (void)error_code;
    return 0;
#endif
}

int32_t swift_mojo_posix_error_is_would_block(int32_t error_code) {
#if SWIFT_MOJO_HAS_POSIX
    return error_code == EAGAIN || error_code == EWOULDBLOCK;
#else
    (void)error_code;
    return 0;
#endif
}

int32_t swift_mojo_posix_termination_signal(void) {
#if SWIFT_MOJO_HAS_POSIX
    return SIGTERM;
#else
    return 15;
#endif
}

int32_t swift_mojo_posix_kill_signal(void) {
#if SWIFT_MOJO_HAS_POSIX
    return SIGKILL;
#else
    return 9;
#endif
}

const char *swift_mojo_posix_error_description(int32_t error_code) {
#if SWIFT_MOJO_HAS_POSIX
    return strerror((int)error_code);
#else
    (void)error_code;
    return "unsupported platform";
#endif
}

void swift_mojo_posix_exit(int32_t status) {
    exit((int)status);
}
