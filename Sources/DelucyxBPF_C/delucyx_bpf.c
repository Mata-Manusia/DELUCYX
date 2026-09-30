#include "delucyx_bpf.h"

#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <net/if.h>
#include <net/bpf.h>
#include <net/ethernet.h>
#include <signal.h>

#define DELUCYX_BPF_MAX_DEVICES 256
#define DELUCYX_ERRBUF_SIZE 256
#define DELUCYX_BPF_BUF_SIZE 65536

static char delucyx_last_error[DELUCYX_ERRBUF_SIZE] = "";

static volatile sig_atomic_t delucyx_stop_flag = 0;

static void delucyx_sig_handler(int sig) {
    (void)sig;
    delucyx_stop_flag = 1;
}

void delucyx_init_signal(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = delucyx_sig_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
}

int delucyx_should_stop(void) {
    return delucyx_stop_flag;
}

struct delucyx_bpf_ctx {
    int fd;
    uint8_t* buf;
    size_t buflen;
    char errbuf[DELUCYX_ERRBUF_SIZE];
    char ifname[IFNAMSIZ];
};

static int bpf_open_device(void) {
    int fd;
    char path[32];
    for (int i = 0; i < DELUCYX_BPF_MAX_DEVICES; i++) {
        snprintf(path, sizeof(path), "/dev/bpf%d", i);
        fd = open(path, O_RDWR);
        if (fd != -1) return fd;
        if (errno == EBUSY) continue;
        if (errno == ENOENT) break;
        return -1;
    }
    return -1;
}

delucyx_bpf_ctx_t* delucyx_bpf_open(const char* interface_name) {
    delucyx_bpf_ctx_t* ctx = calloc(1, sizeof(delucyx_bpf_ctx_t));
    if (!ctx) return NULL;

    ctx->fd = bpf_open_device();
    if (ctx->fd == -1) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "open /dev/bpf*: %s", strerror(errno));
        free(ctx);
        return NULL;
    }

    u_int bufsize = DELUCYX_BPF_BUF_SIZE;
    if (ioctl(ctx->fd, BIOCSBLEN, &bufsize) == -1) {
        bufsize = DELUCYX_BPF_BUF_SIZE;
    }

    struct ifreq ifr;
    memset(&ifr, 0, sizeof(ifr));
    strncpy(ifr.ifr_name, interface_name, sizeof(ifr.ifr_name) - 1);

    if (ioctl(ctx->fd, BIOCSETIF, &ifr) == -1) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "BIOCSETIF %s: %s", interface_name, strerror(errno));
        close(ctx->fd);
        free(ctx);
        return NULL;
    }

    u_int immediate = 1;
    if (ioctl(ctx->fd, BIOCIMMEDIATE, &immediate) == -1) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "BIOCIMMEDIATE: %s", strerror(errno));
        close(ctx->fd);
        free(ctx);
        return NULL;
    }

    if (ioctl(ctx->fd, BIOCPROMISC) == -1) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "BIOCPROMISC: %s", strerror(errno));
        close(ctx->fd);
        free(ctx);
        return NULL;
    }

    u_int hdrcmplt = 1;
    if (ioctl(ctx->fd, BIOCSHDRCMPLT, &hdrcmplt) == -1) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "BIOCSHDRCMPLT: %s", strerror(errno));
        close(ctx->fd);
        free(ctx);
        return NULL;
    }

    if (ioctl(ctx->fd, BIOCGBLEN, &bufsize) == -1) {
        bufsize = DELUCYX_BPF_BUF_SIZE;
    }
    ctx->buf = malloc(bufsize);
    if (!ctx->buf) {
        snprintf(delucyx_last_error, sizeof(delucyx_last_error),
                 "malloc(%u) failed", bufsize);
        close(ctx->fd);
        free(ctx);
        return NULL;
    }
    ctx->buflen = bufsize;

    strncpy(ctx->ifname, interface_name, sizeof(ctx->ifname) - 1);
    ctx->errbuf[0] = '\0';
    return ctx;
}

ssize_t delucyx_bpf_send(delucyx_bpf_ctx_t* ctx, const uint8_t* frame, size_t len) {
    if (!ctx || ctx->fd == -1) {
        if (ctx) snprintf(ctx->errbuf, sizeof(ctx->errbuf), "BPF not open");
        return -1;
    }
    ssize_t written = write(ctx->fd, frame, len);
    if (written == -1) {
        snprintf(ctx->errbuf, sizeof(ctx->errbuf),
                 "write: %s", strerror(errno));
    }
    return written;
}

ssize_t delucyx_bpf_recv(delucyx_bpf_ctx_t* ctx, uint8_t* buf, size_t cap, int timeout_ms) {
    if (!ctx || ctx->fd == -1) {
        if (ctx) snprintf(ctx->errbuf, sizeof(ctx->errbuf), "BPF not open");
        return -1;
    }

    struct timespec ts;
    struct timespec* tsp = NULL;
    if (timeout_ms > 0) {
        ts.tv_sec = timeout_ms / 1000;
        ts.tv_nsec = (long)(timeout_ms % 1000) * 1000000L;
        tsp = &ts;
    }

    fd_set readfds;
    FD_ZERO(&readfds);
    FD_SET(ctx->fd, &readfds);

    int ret;
    do {
        ret = pselect(ctx->fd + 1, &readfds, NULL, NULL, tsp, NULL);
    } while (ret == -1 && errno == EINTR);
    if (ret == -1) {
        int e = errno;
        snprintf(ctx->errbuf, sizeof(ctx->errbuf),
                 "pselect errno=%d: %s", e, strerror(e));
        return -1;
    }
    if (ret == 0) return 0;

    ssize_t n = read(ctx->fd, ctx->buf, ctx->buflen);
    if (n <= 0) {
        if (n == -1) {
            int e = errno;
            snprintf(ctx->errbuf, sizeof(ctx->errbuf),
                     "read errno=%d: %s", e, strerror(e));
        } else {
            snprintf(ctx->errbuf, sizeof(ctx->errbuf),
                     "read returned 0");
        }
        return n;
    }

    if (n < (ssize_t)sizeof(struct bpf_hdr)) {
        snprintf(ctx->errbuf, sizeof(ctx->errbuf),
                 "read: got %zd bytes, need at least %zu", n, sizeof(struct bpf_hdr));
        return -1;
    }
    struct bpf_hdr* hp = (struct bpf_hdr*)ctx->buf;
    uint8_t* frame = ctx->buf + hp->bh_hdrlen;
    uint32_t frame_len = hp->bh_caplen;

    if (frame_len > (uint32_t)n - hp->bh_hdrlen) {
        frame_len = (uint32_t)n - hp->bh_hdrlen;
    }
    if (frame_len > cap) {
        frame_len = (uint32_t)cap;
    }
    memcpy(buf, frame, frame_len);
    return (ssize_t)frame_len;
}

void delucyx_bpf_close(delucyx_bpf_ctx_t* ctx) {
    if (!ctx) return;
    if (ctx->fd != -1) close(ctx->fd);
    ctx->fd = -1;
    free(ctx->buf);
    ctx->buf = NULL;
    free(ctx);
}

const char* delucyx_bpf_error(delucyx_bpf_ctx_t* ctx) {
    if (ctx) return ctx->errbuf[0] ? ctx->errbuf : "unknown error";
    return delucyx_last_error[0] ? delucyx_last_error : "null ctx";
}
