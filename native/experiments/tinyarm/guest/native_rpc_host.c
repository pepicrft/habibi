/* Test-only host adapter. No shares, network, drives, credentials or UI. */
#include "tinyarm.h"
#include <errno.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>

static const char *config;
static atomic_int done;
static int vm_status;

static void output(void *ctx, int channel, const uint8_t *data, size_t len) {
    (void)ctx;
    int fd = channel == 1 ? STDOUT_FILENO : STDERR_FILENO;
    while (len) {
        ssize_t n = write(fd, data, len);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        data += n;
        len -= (size_t)n;
    }
}

static void *run(void *ctx) {
    (void)ctx;
    const char *args[] = {"tinyarm", "-config", config, "-net", "none", "-no-stdin", "-smp", "1", NULL};
    const char *env[] = {NULL};
    tinyarm_set_console_output(output, NULL);
    vm_status = tinyarm_main(8, args, env);
    atomic_store(&done, 1);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: native-rpc-host /absolute/path/to/pack/config\n");
        return 2;
    }
    config = argv[1];
    signal(SIGPIPE, SIG_IGN);
    pthread_t vm;
    pthread_attr_t attributes;
    if (pthread_attr_init(&attributes)) return 2;
    /* TinyARM main.run has a large native stack frame. iOS pthread defaults
       to about 512KiB, which overflows before guest boot. */
    if (pthread_attr_setstacksize(&attributes, 16 * 1024 * 1024)) return 2;
    if (pthread_create(&vm, &attributes, run, NULL)) return 2;
    pthread_attr_destroy(&attributes);
    while (!atomic_load(&done)) {
        struct pollfd fd = {.fd = STDIN_FILENO, .events = POLLIN};
        if (poll(&fd, 1, 100) <= 0) continue;
        uint8_t bytes[4096];
        ssize_t count = read(STDIN_FILENO, bytes, sizeof(bytes));
        if (count <= 0) break;
        size_t offset = 0;
        while (offset < (size_t)count && !atomic_load(&done)) {
            size_t accepted = tinyarm_console_input(1, bytes + offset, (size_t)count - offset);
            offset += accepted;
            if (!accepted) usleep(1000);
        }
    }
    tinyarm_request_stop();
    pthread_join(vm, NULL);
    fprintf(stderr, "\nnative-rpc-host: tinyarm status %d\n", vm_status);
    return vm_status == 78 ? 0 : vm_status;
}
