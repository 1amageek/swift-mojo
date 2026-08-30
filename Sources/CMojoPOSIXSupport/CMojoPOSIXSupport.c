#define _GNU_SOURCE 1

#include "CMojoPOSIXSupport.h"

#include <errno.h>
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
#include <signal.h>
#include <spawn.h>
#include <sys/file.h>
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

static void set_error(int32_t *error_code, int32_t value) {
    if (error_code != NULL) {
        *error_code = value;
    }
}

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
