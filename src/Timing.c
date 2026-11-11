#include "Timing.h"
#include <stdio.h>
#include <time.h>

static double started;
static bool tracing;

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}
void bm_startup_begin(void) { started = now(); }
void bm_startup_trace_enable(bool enabled) { tracing = enabled; }
void bm_startup_mark(const char *stage) {
    if (tracing) fprintf(stderr, "Startup +%8.1f ms: %s\n", (now() - started) * 1000, stage);
}
