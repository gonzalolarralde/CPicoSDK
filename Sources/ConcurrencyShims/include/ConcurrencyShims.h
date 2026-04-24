#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#ifdef __cplusplus
extern "C" {
#endif

// Optional helper APIs for cooperative polling loops.
int cshims_swift_task_poll_once(void);
void cshims_swift_task_drain(void);
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
unsigned int cshims_enter_critical(void);
void cshims_exit_critical(unsigned int state);

// ---------------------------------------------------------------------------
// UNSTABLE DEBUG PROBE: extract the task name from a SwiftJob pointer.
//
// This function uses private Swift runtime internals and will break if the
// runtime layout changes.  It is valid ONLY for:
//
//   runtime commit : 8104e4c3ae46d1211755afa5a709f6b8624c1c79
//   target triple  : armv7em-none-none-eabi  (sizeof(void*) == 4)
//   build mode     : SWIFT_CONCURRENCY_EMBEDDED, no Dispatch
//
// Returns a read-only, null-terminated UTF-8 string when the job is an async
// task created with a name, or NULL in all other cases.  The string is owned
// by the runtime; never free it.
//
// Guarded to ARM only at compile time — returns NULL on every other host.
// ---------------------------------------------------------------------------
const char *cshims_task_get_name_debug(void *job);

#ifdef __cplusplus
}
#endif

#endif
