#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Optional helper APIs for cooperative polling loops.
int cshims_swift_task_poll_once(void);
void cshims_swift_task_drain(void);
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
unsigned int cshims_enter_critical(void);
void cshims_exit_critical(unsigned int state);

// Task name extraction (debug/experimental, ABI-unstable).
//
// These helpers let you inspect an opaque SwiftJob* to determine whether it
// is a Swift Task and, if so, retrieve its debug name. Both functions are
// safe to call from C and return conservative results (false / NULL) when
// name information is unavailable.
//
// See Docs/TASK_NAME_EXTRACTION.md for full documentation, memory-layout
// diagrams, and the ABI-instability caveats that apply to all callers.
bool cshims_job_is_task(const void *job);
const char *cshims_job_get_task_name(const void *job);

#ifdef __cplusplus
}
#endif

#endif
