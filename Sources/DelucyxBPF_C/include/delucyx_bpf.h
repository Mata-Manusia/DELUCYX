#ifndef DELUCYX_BPF_H
#define DELUCYX_BPF_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

typedef struct delucyx_bpf_ctx delucyx_bpf_ctx_t;

delucyx_bpf_ctx_t* delucyx_bpf_open(const char* interface_name);

ssize_t delucyx_bpf_send(delucyx_bpf_ctx_t* ctx, const uint8_t* frame, size_t len);

ssize_t delucyx_bpf_recv(delucyx_bpf_ctx_t* ctx, uint8_t* buf, size_t cap, int timeout_ms);

void delucyx_bpf_close(delucyx_bpf_ctx_t* ctx);

const char* delucyx_bpf_error(delucyx_bpf_ctx_t* ctx);

void delucyx_init_signal(void);
int delucyx_should_stop(void);

#endif
