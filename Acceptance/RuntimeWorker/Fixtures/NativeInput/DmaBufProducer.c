#include "CMojoPOSIXSupportPrivate.h"
#include <poll.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <linux/dma-buf.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
#define REQUIRE(x) do { if (!(x)) { perror(#x); exit(1); } } while(0)
int main(int argc, char **argv) {
    REQUIRE(argc == 2);
    alarm(15);
    int camera=open("/dev/video0",O_RDWR|O_CLOEXEC); REQUIRE(camera>=0);
    struct v4l2_format format={.type=V4L2_BUF_TYPE_VIDEO_CAPTURE};
    REQUIRE(ioctl(camera,VIDIOC_G_FMT,&format)==0);
    printf("format=%ux%u stride=%u fourcc=%08x\n",format.fmt.pix.width,format.fmt.pix.height,format.fmt.pix.bytesperline,format.fmt.pix.pixelformat);
    struct v4l2_requestbuffers request={.count=2,.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.memory=V4L2_MEMORY_MMAP};
    REQUIRE(ioctl(camera,VIDIOC_REQBUFS,&request)==0 && request.count>0);
    struct v4l2_buffer b={.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.memory=V4L2_MEMORY_MMAP,.index=0};
    REQUIRE(ioctl(camera,VIDIOC_QUERYBUF,&b)==0 && b.length>=16);
    struct v4l2_exportbuffer rw={.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.index=0,.flags=O_RDWR|O_CLOEXEC};
    REQUIRE(ioctl(camera,VIDIOC_EXPBUF,&rw)==0);
    struct v4l2_exportbuffer ro={.type=V4L2_BUF_TYPE_VIDEO_CAPTURE,.index=0,.flags=O_RDONLY|O_CLOEXEC};
    REQUIRE(ioctl(camera,VIDIOC_EXPBUF,&ro)==0);
    uint8_t *mapped=mmap(NULL,b.length,PROT_READ|PROT_WRITE,MAP_SHARED,camera,b.m.offset);REQUIRE(mapped!=MAP_FAILED);
    struct dma_buf_sync sync={.flags=DMA_BUF_SYNC_START|DMA_BUF_SYNC_WRITE}; REQUIRE(ioctl(rw.fd,DMA_BUF_IOCTL_SYNC,&sync)==0);
    memset(mapped,0,b.length);
    const uint64_t marker=0x3141592653589793ULL;memcpy(mapped,&marker,sizeof(marker));
    sync.flags=DMA_BUF_SYNC_END|DMA_BUF_SYNC_WRITE;REQUIRE(ioctl(rw.fd,DMA_BUF_IOCTL_SYNC,&sync)==0);
    int sockets[2];REQUIRE(socketpair(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC|SOCK_NONBLOCK,0,sockets)==0);
    fflush(stdout);pid_t child=fork();REQUIRE(child>=0);
    if(child==0) {
        close(sockets[0]);close(camera);close(rw.fd);close(ro.fd);REQUIRE(munmap(mapped,b.length)==0);
        struct pollfd interest={.fd=sockets[1],.events=POLLIN};
        REQUIRE(poll(&interest,1,5000)==1);
        char tag=0;int32_t received=-1,error=0,cleanup=0;uint16_t count=0;
        REQUIRE(swift_mojo_posix_receive_rights(sockets[1],&tag,1,&received,1,&count,&error,&cleanup)==1);
        REQUIRE(tag=='B' && count==1 && error==0 && cleanup==0);
        REQUIRE(fcntl(received,F_SETFD,0)==0);
        close(sockets[1]);
        char descriptor_text[32],extent_text[32];
        snprintf(descriptor_text,sizeof(descriptor_text),"%d",received);
        snprintf(extent_text,sizeof(extent_text),"%u",b.length);
        execl(argv[1],argv[1],descriptor_text,extent_text,(char *)NULL);
        perror("exec resource consumer");_exit(1);
    }
    close(sockets[1]);char tag='B';int32_t error=0,descriptor=ro.fd;
    REQUIRE(swift_mojo_posix_send_rights(sockets[0],&tag,1,&descriptor,1,&error)==1);
    close(sockets[0]);
    int status;REQUIRE(waitpid(child,&status,0)==child && WIFEXITED(status) && WEXITSTATUS(status)==0);
    REQUIRE(munmap(mapped,b.length)==0);close(ro.fd);close(rw.fd);request.count=0;REQUIRE(ioctl(camera,VIDIOC_REQBUFS,&request)==0);close(camera);
    printf("PASS: V4L2 producer -> swift-mojo rights -> public native importer; bytes=%u payload=1 byte; no pixel payload sent\n",b.length);
    return 0;
}
