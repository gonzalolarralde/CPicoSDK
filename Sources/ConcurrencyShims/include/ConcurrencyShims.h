#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uintptr_t swift_threading_defer_current_thread_id(void);
bool swift_threading_defer_is_main_thread(void);
bool swift_threading_defer_current_stack_bounds(void **low, void **high);
void swift_threading_defer_mutex_init(uintptr_t *handle, bool checked);
void swift_threading_defer_mutex_destroy(uintptr_t *handle);
void swift_threading_defer_mutex_lock(uintptr_t *handle);
void swift_threading_defer_mutex_unlock(uintptr_t *handle);
bool swift_threading_defer_mutex_try_lock(uintptr_t *handle);
void swift_threading_defer_recursive_mutex_init(uintptr_t *storage, bool checked);
void swift_threading_defer_recursive_mutex_destroy(uintptr_t *storage);
void swift_threading_defer_recursive_mutex_lock(uintptr_t *storage);
void swift_threading_defer_recursive_mutex_unlock(uintptr_t *storage);
void swift_threading_defer_cond_init(uintptr_t *handle);
void swift_threading_defer_cond_destroy(uintptr_t *handle);
void swift_threading_defer_cond_lock(uintptr_t *handle);
void swift_threading_defer_cond_unlock(uintptr_t *handle);
void swift_threading_defer_cond_signal(uintptr_t *handle);
void swift_threading_defer_cond_broadcast(uintptr_t *handle);
void swift_threading_defer_cond_wait(uintptr_t *handle);
bool swift_threading_defer_cond_wait_for(uintptr_t *handle, uint64_t ns);
bool swift_threading_defer_cond_wait_until(uintptr_t *handle, int64_t epochNs);
void swift_threading_defer_once(uintptr_t *predicate, void (*fn)(void *), void *ctx);
void *swift_threading_defer_tls_get(uintptr_t key);
void swift_threading_defer_tls_set(uintptr_t key, void *value);

// Optional helper APIs for cooperative polling loops.
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
void *cshims_job_owner_task(void *job);
uint8_t cshims_job_priority(void *job);
void cshims_swift_task_clear_current(void);
void *cshims_scheduler_core1_stack_bottom(void);
uint32_t cshims_scheduler_core1_stack_size_bytes(void);
void cshims_scheduler_prepare_lock(void);
int cshims_scheduler_poll_once(void);
void cshims_scheduler_wait_for_work_forever(void);
void cshims_scheduler_start_multicore(void);
void cshims_scheduler_enqueue_deferred(void *item);
void cshims_benchmark_multicore_sequential(
    uint64_t durationUs,
    uint32_t rounds,
    uint32_t *core0Units,
    uint32_t *core1Units,
    uint32_t *core0Checksum,
    uint32_t *core1Checksum,
    uint64_t *elapsedUs);
unsigned int cshims_enter_critical(void);
void cshims_exit_critical(unsigned int state);

typedef void (*cshims_irq_handler_t)(void);
cshims_irq_handler_t cshims_get_irq_wrapper(unsigned int irq);
void cshims_set_irq_wrapper_original(unsigned int irq, cshims_irq_handler_t handler);
cshims_irq_handler_t cshims_get_irq_vtor_handler(unsigned int irq);
void cshims_set_irq_vtor_handler(unsigned int irq, cshims_irq_handler_t handler);

#ifdef __cplusplus
}
#endif

#endif
