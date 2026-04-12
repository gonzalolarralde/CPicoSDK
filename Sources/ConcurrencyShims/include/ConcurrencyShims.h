#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#ifdef __cplusplus
extern "C" {
#endif

void swift_createDefaultExecutorsOnce(void);

// Optional helper APIs for cooperative polling loops.
int cshims_swift_task_poll_once(void);
void cshims_swift_task_drain(void);
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
unsigned int cshims_enter_critical(void);
void cshims_exit_critical(unsigned int state);

#ifdef __cplusplus
}
#endif

#endif
