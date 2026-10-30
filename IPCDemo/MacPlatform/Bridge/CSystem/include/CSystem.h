#ifndef DYNAPET_IPC_SYSTEM_H
#define DYNAPET_IPC_SYSTEM_H
#include <stdint.h>
#include <stddef.h>
int64_t ipc_read_some(int descriptor, uint8_t *buffer, size_t capacity);
int ipc_prepare_signals(void);
int ipc_termination_signal(void);
int ipc_watch_parent(int64_t expected_parent);
int64_t ipc_parent_pid(void);
int64_t ipc_current_pid(void);
void ipc_request_termination(void);
#endif
