#ifndef BM_TIMING_H
#define BM_TIMING_H

#include <stdbool.h>

// Call at main entry; trace output is opt-in and uses a monotonic clock.
void bm_startup_begin(void);
void bm_startup_trace_enable(bool enabled);
void bm_startup_mark(const char *stage);

#endif
