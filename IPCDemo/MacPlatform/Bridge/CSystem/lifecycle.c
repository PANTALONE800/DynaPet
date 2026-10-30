#include "CSystem.h"
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <pthread.h>
#include <time.h>

// Unlike Foundation implementations that try to fill a requested read length,
// one POSIX read returns immediately with any available pipe bytes.
int64_t ipc_read_some(int descriptor, uint8_t *buffer, size_t capacity) {
    ssize_t count;
    do { count = read(descriptor, buffer, capacity); } while (count < 0 && errno == EINTR);
    return (int64_t)count;
}

int ipc_prepare_signals(void) {
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return -1;
    return signal(SIGTERM, SIG_IGN) == SIG_ERR ? -1 : 0;
}
int ipc_termination_signal(void) { return SIGTERM; }
int64_t ipc_parent_pid(void) { return (int64_t)getppid(); }
int64_t ipc_current_pid(void) { return (int64_t)getpid(); }
void ipc_request_termination(void) { kill(getpid(), SIGTERM); }

struct parent_watch { pid_t parent; };
static void *watch_parent(void *raw) {
    struct parent_watch *context = raw;
    const pid_t parent = context->parent;
    free(context);
    const struct timespec interval = {0, 100000000};
    for (;;) {
        if (getppid() != parent || (kill(parent, 0) != 0 && errno == ESRCH)) {
            ipc_request_termination();
            return NULL;
        }
        nanosleep(&interval, NULL);
    }
}

int ipc_watch_parent(int64_t expected_parent) {
    if (expected_parent <= 1 || (int64_t)(pid_t)expected_parent != expected_parent) return -1;
    if (getppid() != (pid_t)expected_parent) { ipc_request_termination(); return 0; }
    struct parent_watch *context = malloc(sizeof(*context));
    if (!context) return -1;
    context->parent = (pid_t)expected_parent;
    pthread_t thread;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes) != 0) { free(context); return -1; }
    if (pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED) != 0) {
        pthread_attr_destroy(&attributes); free(context); return -1;
    }
    const int result = pthread_create(&thread, &attributes, watch_parent, context);
    pthread_attr_destroy(&attributes);
    if (result != 0) free(context);
    return result == 0 ? 0 : -1;
}
