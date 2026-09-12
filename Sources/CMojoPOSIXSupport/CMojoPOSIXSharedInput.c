#define _GNU_SOURCE 1
#include "CMojoPOSIXSupportPrivate.h"
#include <errno.h>
#include <limits.h>
#if defined(__APPLE__) || defined(__GLIBC__)
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#define SWMO_SHARED_POSIX 1
#else
#define SWMO_SHARED_POSIX 0
#endif
#if defined(__linux__) && defined(__GLIBC__)
#include <linux/dma-buf.h>
#include <sys/ioctl.h>
#endif

/* The caller retains the producer's immutable allocation lease throughout all
 * operations. Duplication owns only a descriptor, not the producer's storage.
 * Maps expose initialized bytes read-only; caller joins all readers before
 * END/unmap/close. No pointer is stored here, and no close is retried. */
int32_t swift_mojo_posix_shared_duplicate(
    int32_t source, uint16_t kind, uint64_t byte_count,
    int32_t *error_code, int32_t *cleanup_error
) {
    if (error_code) *error_code = 0;
    if (cleanup_error) *cleanup_error = 0;
#if SWMO_SHARED_POSIX
    if (!error_code || !cleanup_error || !byte_count || byte_count > SIZE_MAX ||
        byte_count > INT64_MAX || (kind != 2 && kind != 3)) {
        if (error_code) *error_code = EINVAL;
        return -1;
    }
#if !defined(__linux__)
    if (kind == 3) { *error_code = ENOTSUP; return -1; }
#endif
    int fd = fcntl(source, F_DUPFD_CLOEXEC, 4);
    if (fd < 0) { *error_code = errno; return -1; }
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) *error_code = errno;
    else if ((flags & O_ACCMODE) != O_RDONLY) *error_code = EACCES;
    if (!*error_code && kind == 2) {
        struct stat metadata;
        if (fstat(fd, &metadata) != 0) *error_code = errno;
        else if (!S_ISREG(metadata.st_mode) || metadata.st_size < 0 ||
                 (uint64_t)metadata.st_size < byte_count) *error_code = EINVAL;
    }
#if defined(__linux__)
    if (!*error_code && kind == 3) {
        /* Qualify the kind before size discovery: seeking an incorrectly
         * labelled regular file would mutate the producer's shared offset. */
        if (swift_mojo_posix_shared_sync(fd, 0, error_code) == 0)
            (void)swift_mojo_posix_shared_sync(fd, 1, error_code);
    }
    if (!*error_code && kind == 3) {
        /* dma-buf supports only these two size-discovery seeks. */
        off_t extent = lseek(fd, 0, SEEK_END);
        if (extent < 0) *error_code = errno;
        else if (lseek(fd, 0, SEEK_SET) < 0) *error_code = errno;
        else if ((uint64_t)extent < byte_count) *error_code = EINVAL;
    }
#endif
    if (*error_code) {
        if (close(fd) != 0) *cleanup_error = errno;
        return -1;
    }
    return fd;
#else
    (void)source; (void)kind; (void)byte_count;
    if (error_code) *error_code = ENOTSUP;
    return -1;
#endif
}

int32_t swift_mojo_posix_shared_sync(int32_t fd, int32_t ending, int32_t *error_code) {
    if (error_code) *error_code = 0;
#if defined(__linux__) && defined(__GLIBC__)
    if (!error_code || (ending != 0 && ending != 1)) {
        if (error_code) *error_code = EINVAL;
        return -1;
    }
    struct dma_buf_sync sync = {
        .flags = DMA_BUF_SYNC_READ | (ending ? DMA_BUF_SYNC_END : DMA_BUF_SYNC_START)
    };
    int result = ioctl(fd, DMA_BUF_IOCTL_SYNC, &sync);
    if (result != 0) *error_code = errno;
    /* EINTR/EAGAIN remain explicit so the owner can enforce its deadline. */
    return result;
#else
    (void)fd; (void)ending;
    if (error_code) *error_code = ENOTSUP;
    return -1;
#endif
}

const void *swift_mojo_posix_shared_map(int32_t fd, uint64_t byte_count, int32_t *error_code) {
    if (error_code) *error_code = 0;
#if SWMO_SHARED_POSIX
    if (!error_code || !byte_count || byte_count > SIZE_MAX || byte_count > INT64_MAX) {
        if (error_code) *error_code = EINVAL;
        return 0;
    }
    void *address = mmap(0, (size_t)byte_count, PROT_READ, MAP_SHARED, fd, 0);
    if (address == MAP_FAILED) { *error_code = errno; return 0; }
    return address;
#else
    (void)fd; (void)byte_count;
    if (error_code) *error_code = ENOTSUP;
    return 0;
#endif
}

int32_t swift_mojo_posix_shared_unmap(const void *address, uint64_t byte_count, int32_t *error_code) {
    if (error_code) *error_code = 0;
#if SWMO_SHARED_POSIX
    if (!error_code || !address || !byte_count || byte_count > SIZE_MAX || byte_count > INT64_MAX) {
        if (error_code) *error_code = EINVAL;
        return -1;
    }
    int result = munmap((void *)address, (size_t)byte_count);
    if (result != 0) *error_code = errno;
    return result;
#else
    (void)address; (void)byte_count;
    if (error_code) *error_code = ENOTSUP;
    return -1;
#endif
}
