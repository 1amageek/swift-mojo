#ifndef SWIFT_MOJO_C_POSIX_SUPPORT_H
#define SWIFT_MOJO_C_POSIX_SUPPORT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int32_t swift_mojo_posix_platform_supported(void);

int32_t swift_mojo_posix_open_file(
    const char *path,
    int32_t truncate,
    int32_t *error_code
);

int32_t swift_mojo_posix_close_file(
    int32_t descriptor,
    int32_t *error_code
);

int32_t swift_mojo_posix_lock_exclusive(
    int32_t descriptor,
    int32_t *error_code
);

int32_t swift_mojo_posix_try_lock_exclusive(
    int32_t descriptor,
    int32_t *error_code
);

int32_t swift_mojo_posix_unlock(
    int32_t descriptor,
    int32_t *error_code
);

enum {
    SWIFT_MOJO_POSIX_SPAWN_SUCCEEDED = 0,
    SWIFT_MOJO_POSIX_SPAWN_SETUP_FAILED = -1,
    SWIFT_MOJO_POSIX_SPAWN_LAUNCH_FAILED = -2,
};

int32_t swift_mojo_posix_spawn(
    const char *executable,
    char *const arguments[],
    char *const environment[],
    int32_t output_descriptor,
    int32_t *process_id,
    int32_t *error_code
);

int32_t swift_mojo_posix_wait_nohang(
    int32_t process_id,
    int32_t *wait_status,
    int32_t *error_code
);

int32_t swift_mojo_posix_signal_group(
    int32_t process_id,
    int32_t signal_number,
    int32_t *error_code
);

int32_t swift_mojo_posix_process_group_alive(int32_t process_id);

int32_t swift_mojo_posix_process_alive(int32_t process_id);

int64_t swift_mojo_posix_seek_start(
    int32_t descriptor,
    int32_t *error_code
);

int64_t swift_mojo_posix_read(
    int32_t descriptor,
    void *buffer,
    int64_t count,
    int32_t *error_code
);

int32_t swift_mojo_posix_error_is_no_child(int32_t error_code);

int32_t swift_mojo_posix_termination_signal(void);

int32_t swift_mojo_posix_kill_signal(void);

const char *swift_mojo_posix_error_description(int32_t error_code);

void swift_mojo_posix_exit(int32_t status);

#ifdef __cplusplus
}
#endif

#endif
