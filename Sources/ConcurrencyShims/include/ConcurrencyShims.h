#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__has_include) && __has_include(<swift/EmbeddedPlatform.h>)
#include <swift/EmbeddedPlatform.h>
#else
typedef __SIZE_TYPE__ __swift_size_t;
typedef __PTRDIFF_TYPE__ __swift_ptrdiff_t;
typedef unsigned long long __swift_options_t;
typedef __swift_ptrdiff_t swift_tls_key_t;
typedef void (*__swift_tls_dtor_t)(void *);

#define SWIFT_TLS_KEY_COUNT 8
#define EMBEDDED_SWIFT_MUTEX_NUM_WORDS (__swift_ptrdiff_t)8
#define EMBEDDED_SWIFT_MUTEX_RECURSIVE_NUM_WORDS (__swift_ptrdiff_t)8

typedef enum : __swift_options_t {
    SWIFT_MUTEX_NONE = 0,
    SWIFT_MUTEX_CHECKED = 0x01
} swift_mutex_flags_t;

void _swift_mutex_init(void *mutex, swift_mutex_flags_t flags);
void _swift_mutex_destroy(void *mutex);
void _swift_mutex_lock(void *mutex);
void _swift_mutex_unlock(void *mutex);
__swift_ptrdiff_t _swift_mutex_tryLock(void *mutex);
void _swift_mutexRecursive_init(void *mutex, swift_mutex_flags_t flags);
void _swift_mutexRecursive_destroy(void *mutex);
void _swift_mutexRecursive_lock(void *mutex);
void _swift_mutexRecursive_unlock(void *mutex);
void _swift_tls_init(swift_tls_key_t key, __swift_tls_dtor_t destructor);
void *_swift_tls_get(swift_tls_key_t key);
void _swift_tls_set(swift_tls_key_t key, void *value);
__swift_ptrdiff_t _swift_thread_isMain(void);
#endif

// Optional helper APIs for cooperative polling loops.
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
void *cshims_job_owner_task(void *job);
uint8_t cshims_job_priority(void *job);
void cshims_swift_task_clear_current(void);
void cshims_scheduler_prepare_lock(void);
int cshims_scheduler_poll_once(void);
void cshims_scheduler_wait_for_work_forever(void);
bool cshims_scheduler_start_multicore(void);
void cshims_scheduler_enqueue_deferred(void *item);
void *cshims_scheduler_core1_stack_bottom(void);
uint32_t cshims_scheduler_core1_stack_size_bytes(void);
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

typedef struct {
    uint64_t timestampUs;
    uint32_t core;
    uint32_t flags;
    uint64_t taskUs;
    uint64_t interruptUs;
    uint64_t idleUs;
    uint64_t totalUs;
    uint64_t interruptEvents;
    uint64_t taskCycles;
    uint64_t interruptCycles;
    uint64_t idleCycles;
    uint64_t totalCycles;
    uint64_t taskLoadStoreStallCount;
    uint64_t interruptLoadStoreStallCount;
    uint64_t idleLoadStoreStallCount;
    uint64_t loadStoreStallCount;
} cshims_cpu_metrics_report_t;

enum {
    CSHIMS_CPU_METRICS_REPORT_HAS_CYCLES = 1u << 0,
    CSHIMS_CPU_METRICS_REPORT_HAS_LOAD_STORE_STALLS = 1u << 1,
};

void cshims_cpu_metrics_record_task_start(uint32_t core);
void cshims_cpu_metrics_record_task_end(uint32_t core);
void cshims_cpu_metrics_record_idle_sample(uint32_t core);
void cshims_cpu_metrics_record_interrupt_enter(uint32_t core);
void cshims_cpu_metrics_record_interrupt_exit(uint32_t core);
void cshims_cpu_metrics_record_interrupt_sample(uint32_t core, uint64_t events, uint64_t timeUs);
void cshims_cpu_metrics_take_interrupt_samples(uint32_t core, uint64_t *events, uint64_t *timeUs);
bool cshims_cpu_metrics_take_report(uint32_t core, cshims_cpu_metrics_report_t *report);
void cshims_cpu_metrics_set_enabled(bool enabled);

#ifdef __cplusplus
}
#endif

#endif
