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

// ---- Unstable task-introspection helpers ------------------------------------
//
// These two functions expose private Swift runtime internals.  They are
// intended for debug/tracing use only and are NOT ABI-stable.  They may
// silently return wrong values or crash if used outside the specific Swift
// runtime commit and target they were derived for.
//
// See Sources/ConcurrencyShims/include/SwiftJobInternals.h for the full
// source-reference commentary, layout derivation, and stability caveats.

// Return the raw JobFlags word from any SwiftJob pointer.
// Bits 0–7  : JobKind  (0 = Task / AsyncTask).
// Bit  30   : Task_HasInitialTaskName.
// Returns 0 on NULL input.
// ARM Cortex-M (armv7em) only; returns 0 on other architectures.
unsigned int cshims_job_get_flags(void *job);

// Return the NUL-terminated task name for the given SwiftJob*, or NULL if:
//   • job is NULL,
//   • the job is not an AsyncTask (JobKind != 0),
//   • the task has no initial name (bit 30 of JobFlags is clear), or
//   • no TaskNameStatusRecord was found in the status record chain.
// ARM Cortex-M (armv7em) only; always returns NULL on other architectures.
const char *cshims_job_get_task_name(void *job);

#ifdef __cplusplus
}
#endif

#endif
