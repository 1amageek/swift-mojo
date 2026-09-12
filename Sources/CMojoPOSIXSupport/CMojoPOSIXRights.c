#define _GNU_SOURCE 1
#include "CMojoPOSIXSupportPrivate.h"
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__) || defined(__GLIBC__)
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <unistd.h>
#define SWMO_RIGHTS_POSIX 1
#else
#define SWMO_RIGHTS_POSIX 0
#endif

/* Ancillary storage is call-owned, malloc-aligned and freed exactly once.
 * Payload/descriptor pointers are borrowed only through the synchronous syscall.
 * Received descriptors become caller-owned only on success; every failure
 * consumes all installed slots, including close failures, without retrying
 * descriptor numbers that the OS could reuse. No state is shared across calls. */
#if SWMO_RIGHTS_POSIX
static void consume_right(int32_t *slot, int32_t *cleanup_error) {
    int fd = *slot;
    *slot = -1;
    if (fd >= 0 && close(fd) != 0 && *cleanup_error == 0) *cleanup_error = errno;
}

static int require_nonblocking(int fd, int32_t *error_code) {
    int flags = fcntl(fd, F_GETFL);
    if (flags < 0) { *error_code = errno; return -1; }
    if (!(flags & O_NONBLOCK)) { *error_code = EINVAL; return -1; }
    return 0;
}
#endif

int64_t swift_mojo_posix_send_rights(
    int32_t socket_fd, const void *bytes, int64_t byte_count,
    const int32_t *rights, uint16_t right_count, int32_t *error_code
) {
    if (error_code) *error_code = 0;
#if SWMO_RIGHTS_POSIX
    if (!error_code || !bytes || byte_count <= 0 ||
        (uint64_t)byte_count > (uint64_t)SSIZE_MAX || !rights || !right_count) {
        if (error_code) *error_code = EINVAL;
        return -1;
    }
    /* Darwin sendmsg can block despite MSG_DONTWAIT on a blocking socket. */
    if (require_nonblocking(socket_fd, error_code) != 0) return -1;
    size_t control_size = CMSG_SPACE((size_t)right_count * sizeof(int));
    void *control = calloc(1, control_size);
    if (!control) { *error_code = ENOMEM; return -1; }
    struct iovec io = {.iov_base = (void *)bytes, .iov_len = (size_t)byte_count};
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &io;
    message.msg_iovlen = 1;
    message.msg_control = control;
    /* UInt16 descriptor count bounds ancillary storage below UINT32_MAX. */
    message.msg_controllen = (uint32_t)control_size;
    struct cmsghdr *header = CMSG_FIRSTHDR(&message);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = (uint32_t)CMSG_LEN((size_t)right_count * sizeof(int));
    for (uint16_t i = 0; i < right_count; ++i) {
        int fd = rights[i];
        memcpy((unsigned char *)CMSG_DATA(header) + (size_t)i * sizeof(int), &fd, sizeof(fd));
    }
    int flags = MSG_DONTWAIT;
#ifdef MSG_NOSIGNAL
    flags |= MSG_NOSIGNAL;
#endif
    ssize_t count = sendmsg(socket_fd, &message, flags);
    if (count < 0) *error_code = errno;
    free(control);
    return count;
#else
    (void)socket_fd; (void)bytes; (void)byte_count; (void)rights; (void)right_count;
    if (error_code) *error_code = ENOTSUP;
    return -1;
#endif
}

int64_t swift_mojo_posix_receive_rights(
    int32_t socket_fd, void *bytes, int64_t byte_count,
    int32_t *rights, uint16_t right_capacity, uint16_t *right_count,
    int32_t *error_code, int32_t *cleanup_error
) {
    if (error_code) *error_code = 0;
    if (cleanup_error) *cleanup_error = 0;
    if (right_count) *right_count = 0;
#if SWMO_RIGHTS_POSIX
    if (!error_code || !cleanup_error || !right_count || !bytes ||
        byte_count <= 0 || (uint64_t)byte_count > (uint64_t)SSIZE_MAX ||
        (right_capacity && !rights)) {
        if (error_code) *error_code = EINVAL;
        return -1;
    }
    for (uint16_t i = 0; i < right_capacity; ++i) rights[i] = -1;
    if (require_nonblocking(socket_fd, error_code) != 0) return -1;
    /* Linux closes truncated rights. Darwin externalizes the full rights set
     * before truncating the user control buffer, so receive its kernel maximum
     * (XNU UIPC_MAX_CMSG_FD = 512), then enforce the caller's smaller capacity.
     * Never rely on Darwin MSG_CTRUNC to close undisclosed descriptors. */
#if defined(__APPLE__)
    size_t slots = 512;
#else
    size_t slots = right_capacity ? right_capacity : 1;
#endif
    size_t control_size = CMSG_SPACE(slots * sizeof(int));
    void *control = calloc(1, control_size);
    if (!control) { *error_code = ENOMEM; return -1; }
    struct iovec io = {.iov_base = bytes, .iov_len = (size_t)byte_count};
    struct msghdr message;
    memset(&message, 0, sizeof(message));
    message.msg_iov = &io;
    message.msg_iovlen = 1;
    message.msg_control = control;
    message.msg_controllen = (uint32_t)control_size;
    int flags = MSG_DONTWAIT;
#ifdef MSG_CMSG_CLOEXEC
    flags |= MSG_CMSG_CLOEXEC;
#endif
    ssize_t count = recvmsg(socket_fd, &message, flags);
    if (count < 0) { *error_code = errno; free(control); return -1; }
    unsigned sets = 0;
    for (struct cmsghdr *h = CMSG_FIRSTHDR(&message); h; h = CMSG_NXTHDR(&message, h)) {
        size_t offset = (size_t)((unsigned char *)h - (unsigned char *)control);
        size_t available = message.msg_controllen < control_size ? message.msg_controllen : control_size;
        if (offset > available || available - offset < CMSG_LEN(0)) {
            *error_code = EPROTO;
            break;
        }
        if (h->cmsg_level != SOL_SOCKET || h->cmsg_type != SCM_RIGHTS ||
            h->cmsg_len < CMSG_LEN(0)) {
            *error_code = EPROTO;
            continue;
        }
        ++sets;
        size_t length = h->cmsg_len - CMSG_LEN(0);
        size_t capacity = available - offset - CMSG_LEN(0);
        /* Darwin may preserve the original cmsg_len after truncation. Only
         * descriptors actually installed in the returned storage are owned. */
        int truncated = length > capacity;
        if (truncated) { length = capacity; *error_code = EPROTO; }
        if (length % sizeof(int)) *error_code = EPROTO;
        size_t descriptors = length / sizeof(int);
        for (size_t i = 0; i < descriptors; ++i) {
            int fd;
            memcpy(&fd, (unsigned char *)CMSG_DATA(h) + i * sizeof(int), sizeof(fd));
            int32_t slot = fd;
            if (*right_count >= right_capacity) {
                *error_code = EPROTO;
                consume_right(&slot, cleanup_error);
                continue;
            }
            rights[*right_count] = slot;
            ++*right_count;
#ifndef MSG_CMSG_CLOEXEC
            if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 && *error_code == 0) *error_code = errno;
#endif
        }
        if (truncated) break;
    }
    if (sets > 1 || (message.msg_flags & (MSG_CTRUNC | MSG_TRUNC))) *error_code = EPROTO;
    if (*error_code) {
        for (uint16_t i = 0; i < *right_count; ++i) consume_right(&rights[i], cleanup_error);
        *right_count = 0;
        free(control);
        return -1;
    }
    free(control);
    return count;
#else
    (void)socket_fd; (void)bytes; (void)byte_count; (void)rights; (void)right_capacity;
    if (error_code) *error_code = ENOTSUP;
    return -1;
#endif
}
