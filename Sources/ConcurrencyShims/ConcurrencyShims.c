#include "ConcurrencyShims.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <time.h>

#if defined(__clang__)
#define SWIFT_CC_SWIFT __attribute__((swiftcall))
#if __has_attribute(swiftasynccall)
#define SWIFT_CC_SWIFT_ASYNC __attribute__((swiftasynccall))
#else
#define SWIFT_CC_SWIFT_ASYNC __attribute__((swiftcall))
#endif
#define SWIFT_NORETURN __attribute__((noreturn))
#else
#define SWIFT_CC_SWIFT
#define SWIFT_CC_SWIFT_ASYNC
#define SWIFT_NORETURN
#endif

typedef struct {
    void *first;
    void *second;
} SwiftExecutorRef;

extern void SWIFT_CC_SWIFT swift_job_run(void *job, void *executorFirst, void *executorSecond);
extern uint64_t SWIFT_CC_SWIFT swift_task_getJobTaskId(void *job);
extern void *SWIFT_CC_SWIFT swift_task_getCurrent(void);
extern bool SWIFT_CC_SWIFT swift_task_isCurrentExecutor(SwiftExecutorRef executor);
extern void *SWIFT_CC_SWIFT __real_swift_task_getCurrent(void);
extern void *SWIFT_CC_SWIFT __real_swift_task_alloc(size_t size);
extern void SWIFT_CC_SWIFT __real_swift_task_dealloc(void *ptr);
extern void SWIFT_CC_SWIFT __real_swift_task_dealloc_through(void *ptr);
extern void *SWIFT_CC_SWIFT __real_swift_continuation_init(void *context, uint32_t flags);
extern void SWIFT_CC_SWIFT __real_swift_continuation_resume(void *task);
extern void SWIFT_CC_SWIFT __real_swift_task_enqueue(void *job, void *executorFirst, void *executorSecond);
extern void SWIFT_CC_SWIFT __real_swift_job_run(void *job, void *executorFirst, void *executorSecond);
#ifndef CSHIMS_WRAP_SWIFT_TASK_SWITCH
#define CSHIMS_WRAP_SWIFT_TASK_SWITCH 0
#endif
#if CSHIMS_WRAP_SWIFT_TASK_SWITCH
extern void SWIFT_CC_SWIFT_ASYNC __real_swift_task_switch(
    void *resumeContext,
    void *resumeFunction,
    void *executorFirst,
    void *executorSecond
);
#endif
extern void *SWIFT_CC_SWIFT cshims_swift_task_set_current(void *task) __asm__("_ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE");
extern void *SWIFT_CC_SWIFT cshims_swift_task_clear_current(void) __asm__("_ZN5swift24_swift_task_clearCurrentEv");
extern void *SWIFT_CC_SWIFT __real__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE(void *task);
extern void *SWIFT_CC_SWIFT __real__ZN5swift24_swift_task_clearCurrentEv(void);
extern void *__wrap__ZN5swift26_swift_task_alloc_specificEPNS_9AsyncTaskEj(void *task, size_t size);
extern void __wrap__ZN5swift28_swift_task_dealloc_specificEPNS_9AsyncTaskEPv(void *task, void *ptr);
extern void *__real__ZN5swift26_swift_task_alloc_specificEPNS_9AsyncTaskEj(void *task, size_t size);
extern void __real__ZN5swift28_swift_task_dealloc_specificEPNS_9AsyncTaskEPv(void *task, void *ptr);
extern const void *cshims_swift_task_heap_metadata_ptr __asm__("_ZN5swift19taskHeapMetadataPtrE");
extern void *__real_malloc(size_t size);
extern void __real_free(void *ptr);

static volatile uint32_t cshims_heap_lock_word = 0;

static void cshims_heap_lock(void) {
    while (__atomic_exchange_n(&cshims_heap_lock_word, 1, __ATOMIC_ACQUIRE) != 0) {
        __asm volatile("nop");
    }
}

static void cshims_heap_unlock(void) {
    __atomic_store_n(&cshims_heap_lock_word, 0, __ATOMIC_RELEASE);
}

static void *cshims_swift_task_heap_alloc(size_t size) {
    cshims_heap_lock();
    void *ptr = __real_malloc(size);
    cshims_heap_unlock();
    return ptr;
}

static void cshims_swift_task_heap_free(void *ptr) {
    cshims_heap_lock();
    __real_free(ptr);
    cshims_heap_unlock();
}

static unsigned int cshims_core_num(void) {
    return *(volatile uint32_t *)0xd0000000u;
}

extern int cshims_scheduler_poll_once(void);
extern void cshims_scheduler_drain(void);
extern void cshims_scheduler_enqueue_immediate(void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_enqueue_delayed(uint64_t delayUs, void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_enqueue_deadline(uint64_t deadlineUs, void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_wait_for_work_forever(void);
extern void cshims_scheduler_core1_boot(void);
extern void cshims_scheduler_core1_seed(void);
extern int cshims_scheduler_core1_loop_iteration(void);
extern void multicore_reset_core1(void);
extern void multicore_launch_core1_with_stack(void (*entry)(void), uint32_t *stack_bottom, size_t stack_size_bytes);
extern void sleep_us(uint64_t us);

#define CSHIMS_CORE1_STACK_WORDS 4096

static uint32_t cshims_core1_stack[CSHIMS_CORE1_STACK_WORDS] __attribute__((aligned(8)));
static uint32_t cshims_tls_probe_core1_stack[512] __attribute__((aligned(8)));

static volatile uint32_t cshims_tls_probe_done;
static volatile uintptr_t cshims_tls_probe_core1_before;
static volatile uintptr_t cshims_tls_probe_core1_after;

static void *cshims_current_tasks[2];

static SwiftExecutorRef cshims_generic_executor(void) {
    SwiftExecutorRef executor = {NULL, NULL};
    return executor;
}

static bool cshims_executor_is_generic(SwiftExecutorRef executor) {
    return executor.first == NULL && executor.second == NULL;
}

static bool cshims_executor_equal(SwiftExecutorRef lhs, SwiftExecutorRef rhs) {
    return lhs.first == rhs.first && lhs.second == rhs.second;
}

static unsigned int cshims_core_index(void) {
    return cshims_core_num() & 1u;
}

static void *cshims_get_current_task_for_core(void) {
    return cshims_current_tasks[cshims_core_index()];
}

static void *cshims_set_current_task_for_core(void *task) {
    unsigned int core = cshims_core_index();
    void *old = cshims_current_tasks[core];
    cshims_current_tasks[core] = task;
    return old;
}

static void cshims_set_current_task_for_core_index(unsigned int core, void *task) {
    cshims_current_tasks[core & 1u] = task;
}

void *SWIFT_CC_SWIFT __wrap_swift_task_getCurrent(void) {
    return cshims_get_current_task_for_core();
}

void *SWIFT_CC_SWIFT __wrap__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE(void *task) {
    void *old = cshims_set_current_task_for_core(task);
    __real__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE(task);
    return old;
}

void *SWIFT_CC_SWIFT __wrap__ZN5swift24_swift_task_clearCurrentEv(void) {
    void *old = cshims_set_current_task_for_core(NULL);
    __real__ZN5swift24_swift_task_clearCurrentEv();
    return old;
}

static void cshims_tls_probe_core1_entry(void) {
    cshims_tls_probe_core1_before = (uintptr_t)swift_task_getCurrent();
    cshims_swift_task_set_current((void *)0xc1000001u);
    cshims_tls_probe_core1_after = (uintptr_t)swift_task_getCurrent();
    cshims_tls_probe_done = 1;
    for (;;) {
        sleep_us(1000);
    }
}

void cshims_tls_probe_run(void) {
    cshims_tls_probe_done = 0;
    cshims_tls_probe_core1_before = 0;
    cshims_tls_probe_core1_after = 0;

    void *saved = cshims_set_current_task_for_core((void *)0xc0000000u);
    __real__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE((void *)0xc0000000u);
    uintptr_t core0Before = (uintptr_t)swift_task_getCurrent();

    multicore_reset_core1();
    multicore_launch_core1_with_stack(
        cshims_tls_probe_core1_entry,
        cshims_tls_probe_core1_stack,
        sizeof(cshims_tls_probe_core1_stack));

    for (uint32_t i = 0; i < 100000u && !cshims_tls_probe_done; i++) {
        sleep_us(10);
    }

    uintptr_t core0After = (uintptr_t)swift_task_getCurrent();
    printf("currentprobe done=%lu saved=%p c0b=%lx c0a=%lx c1b=%lx c1a=%lx leaked=%u\n",
           (unsigned long)cshims_tls_probe_done,
           saved,
           (unsigned long)core0Before,
           (unsigned long)core0After,
           (unsigned long)cshims_tls_probe_core1_before,
           (unsigned long)cshims_tls_probe_core1_after,
           core0After == 0xc1000001u ? 1u : 0u);

    cshims_set_current_task_for_core(saved);
    __real__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE(saved);
    cshims_set_current_task_for_core_index(1, NULL);
    multicore_reset_core1();
}

#ifndef CSHIMS_SWIFT_TASK_ALLOC_TRACE
#define CSHIMS_SWIFT_TASK_ALLOC_TRACE 0
#endif

#ifndef CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
#define CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP 1
#endif

#define CSHIMS_TASK_ALLOC_TRACK_COUNT 192u

typedef struct {
    void *ptr;
    void *task;
    size_t size;
    uint32_t seq;
    uint8_t kind;
} CShimsTaskAllocRecord;

static CShimsTaskAllocRecord cshims_task_alloc_records[CSHIMS_TASK_ALLOC_TRACK_COUNT];
static uint32_t cshims_task_alloc_seq;
static uint32_t cshims_task_alloc_misses;
static uint32_t cshims_task_alloc_non_lifo;

static uint32_t cshims_task_alloc_lock(void) {
    return cshims_enter_critical();
}

static void cshims_task_alloc_unlock(uint32_t state) {
    cshims_exit_critical(state);
}

static int cshims_task_alloc_find_locked(void *ptr) {
    for (uint32_t i = 0; i < CSHIMS_TASK_ALLOC_TRACK_COUNT; i++) {
        if (cshims_task_alloc_records[i].ptr == ptr) {
            return (int)i;
        }
    }
    return -1;
}

static int cshims_task_alloc_empty_slot_locked(void) {
    for (uint32_t i = 0; i < CSHIMS_TASK_ALLOC_TRACK_COUNT; i++) {
        if (cshims_task_alloc_records[i].ptr == NULL) {
            return (int)i;
        }
    }
    return -1;
}

static bool cshims_task_alloc_is_top_locked(void *task, uint32_t seq) {
    uint32_t top = 0;
    for (uint32_t i = 0; i < CSHIMS_TASK_ALLOC_TRACK_COUNT; i++) {
        CShimsTaskAllocRecord *record = &cshims_task_alloc_records[i];
        if (record->ptr != NULL && record->task == task && record->seq > top) {
            top = record->seq;
        }
    }
    return top == seq;
}

static void cshims_task_alloc_record_alloc(void *ptr, void *task, size_t size, uint8_t kind) {
    if (ptr == NULL) {
        return;
    }

    uint32_t state = cshims_task_alloc_lock();
    int slot = cshims_task_alloc_empty_slot_locked();
    uint32_t seq = ++cshims_task_alloc_seq;
    if (slot >= 0) {
        cshims_task_alloc_records[slot] = (CShimsTaskAllocRecord){
            .ptr = ptr,
            .task = task,
            .size = size,
            .seq = seq,
            .kind = kind,
        };
    } else {
        cshims_task_alloc_misses++;
    }
    uint32_t misses = cshims_task_alloc_misses;
    cshims_task_alloc_unlock(state);

#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    if (slot < 0 || seq <= 80u || cshims_core_num() == 1u) {
        printf("ta%c c=%u t=%p p=%p sz=%u s=%lu miss=%lu\n",
               kind, cshims_core_num(), task, ptr, (unsigned)size,
               (unsigned long)seq, (unsigned long)misses);
    }
#endif
}

static void cshims_task_alloc_record_dealloc(void *ptr, void *task, uint8_t kind, bool through) {
    if (ptr == NULL) {
        return;
    }

    CShimsTaskAllocRecord removed = {0};
    bool found = false;
    bool nonLifo = false;
    uint32_t misses;
    uint32_t nonLifoCount;

    uint32_t state = cshims_task_alloc_lock();
    int slot = cshims_task_alloc_find_locked(ptr);
    if (slot >= 0) {
        found = true;
        removed = cshims_task_alloc_records[slot];
        nonLifo = !through && !cshims_task_alloc_is_top_locked(removed.task, removed.seq);
        if (nonLifo) {
            cshims_task_alloc_non_lifo++;
        }
        if (through) {
            for (uint32_t i = 0; i < CSHIMS_TASK_ALLOC_TRACK_COUNT; i++) {
                CShimsTaskAllocRecord *record = &cshims_task_alloc_records[i];
                if (record->ptr != NULL && record->task == removed.task && record->seq >= removed.seq) {
                    *record = (CShimsTaskAllocRecord){0};
                }
            }
        } else {
            cshims_task_alloc_records[slot] = (CShimsTaskAllocRecord){0};
        }
    } else {
        cshims_task_alloc_misses++;
    }
    misses = cshims_task_alloc_misses;
    nonLifoCount = cshims_task_alloc_non_lifo;
    cshims_task_alloc_unlock(state);

#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    if (!found || nonLifo || cshims_core_num() == 1u) {
        printf("td%c%s c=%u cur=%p rt=%p p=%p s=%lu ok=%u nl=%u miss=%lu nlc=%lu\n",
               kind, through ? "T" : "", cshims_core_num(), task, removed.task, ptr,
               (unsigned long)removed.seq, found ? 1u : 0u, nonLifo ? 1u : 0u,
               (unsigned long)misses, (unsigned long)nonLifoCount);
    }
#endif
}

void swift_createDefaultExecutors(void) {}

void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond) {
    swift_job_run(job, executorFirst, executorSecond);
}

uint64_t cshims_job_task_id(void *job) {
    if (job == NULL) {
        return 0;
    }
    return swift_task_getJobTaskId(job);
}

void *cshims_job_async_task(void *job) {
    if (job == NULL) {
        return NULL;
    }

    void *metadata;
    memcpy(&metadata, job, sizeof(metadata));

    const void *taskMetadata = cshims_swift_task_heap_metadata_ptr;
    if (metadata == taskMetadata) {
        return job;
    }

    return NULL;
}

void *cshims_current_task(void) {
    return cshims_get_current_task_for_core();
}

void *SWIFT_CC_SWIFT __wrap_swift_task_alloc(size_t size) {
    void *task = cshims_get_current_task_for_core();
#if CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
    void *ptr = cshims_swift_task_heap_alloc(size);
#else
    void *ptr = __real_swift_task_alloc(size);
#endif
    cshims_task_alloc_record_alloc(ptr, task, size, 'p');
    return ptr;
}

void SWIFT_CC_SWIFT __wrap_swift_task_dealloc(void *ptr) {
    void *task = cshims_get_current_task_for_core();
    cshims_task_alloc_record_dealloc(ptr, task, 'p', false);
#if CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
    cshims_swift_task_heap_free(ptr);
#else
    __real_swift_task_dealloc(ptr);
#endif
}

void SWIFT_CC_SWIFT __wrap_swift_task_dealloc_through(void *ptr) {
    void *task = cshims_get_current_task_for_core();
    cshims_task_alloc_record_dealloc(ptr, task, 'p', true);
#if CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
    cshims_swift_task_heap_free(ptr);
#else
    __real_swift_task_dealloc_through(ptr);
#endif
}

void *__wrap__ZN5swift26_swift_task_alloc_specificEPNS_9AsyncTaskEj(void *task, size_t size) {
#if CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
    void *ptr = cshims_swift_task_heap_alloc(size);
#else
    void *ptr = __real__ZN5swift26_swift_task_alloc_specificEPNS_9AsyncTaskEj(task, size);
#endif
    cshims_task_alloc_record_alloc(ptr, task, size, 's');
    return ptr;
}

void __wrap__ZN5swift28_swift_task_dealloc_specificEPNS_9AsyncTaskEPv(void *task, void *ptr) {
    cshims_task_alloc_record_dealloc(ptr, task, 's', false);
#if CSHIMS_SWIFT_TASK_ALLOC_USE_HEAP
    cshims_swift_task_heap_free(ptr);
#else
    __real__ZN5swift28_swift_task_dealloc_specificEPNS_9AsyncTaskEPv(task, ptr);
#endif
}

void *SWIFT_CC_SWIFT __wrap_swift_continuation_init(void *context, uint32_t flags) {
    void *before = cshims_get_current_task_for_core();
    void *task = __real_swift_continuation_init(context, flags);
#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    printf("ci c=%u cur=%p task=%p ctx=%p fl=%lx\n",
           cshims_core_num(), before, task, context, (unsigned long)flags);
#endif
    return task;
}

void SWIFT_CC_SWIFT __wrap_swift_continuation_resume(void *task) {
#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    printf("cr c=%u cur=%p task=%p\n", cshims_core_num(), cshims_get_current_task_for_core(), task);
#endif
    __real_swift_continuation_resume(task);
}

void SWIFT_CC_SWIFT __wrap_swift_task_enqueue(void *job, void *executorFirst, void *executorSecond) {
#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    printf("enq c=%u cur=%p job=%p ex=%p/%p jt=%p\n",
           cshims_core_num(), cshims_get_current_task_for_core(),
           job, executorFirst, executorSecond, cshims_job_async_task(job));
#endif
    cshims_scheduler_enqueue_immediate(job, executorFirst, executorSecond);
}

#if CSHIMS_WRAP_SWIFT_TASK_SWITCH
void SWIFT_CC_SWIFT_ASYNC __wrap_swift_task_switch(
    void *resumeContext,
    void *resumeFunction,
    void *executorFirst,
    void *executorSecond
) {
    void *task = cshims_get_current_task_for_core();
    if (task != NULL) {
        __real__ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE(task);
    }
    __real_swift_task_switch(resumeContext, resumeFunction, executorFirst, executorSecond);
}
#endif

void SWIFT_CC_SWIFT __wrap_swift_job_run(void *job, void *executorFirst, void *executorSecond) {
    void *jobTask = cshims_job_async_task(job);
    void *oldTask = cshims_get_current_task_for_core();
    if (jobTask != NULL) {
        cshims_set_current_task_for_core(jobTask);
    }
#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    printf("jr c=%u cur=%p real=%p job=%p jt=%p\n",
           cshims_core_num(), cshims_get_current_task_for_core(), __real_swift_task_getCurrent(), job, jobTask);
#endif
    __real_swift_job_run(job, executorFirst, executorSecond);
#if CSHIMS_SWIFT_TASK_ALLOC_TRACE
    printf("jx c=%u cur=%p real=%p job=%p jt=%p\n",
           cshims_core_num(), cshims_get_current_task_for_core(), __real_swift_task_getCurrent(), job, jobTask);
#endif
    if (jobTask != NULL) {
        cshims_set_current_task_for_core(oldTask);
    }
}

static void cshims_scheduler_core1_entry(void) {
    cshims_set_current_task_for_core(NULL);
    cshims_scheduler_core1_boot();
    cshims_scheduler_core1_seed();
    for (;;) {
        if (!cshims_scheduler_core1_loop_iteration()) {
            sleep_us(50);
        }
    }
}

void cshims_scheduler_launch_core1(void) {
    multicore_reset_core1();
    multicore_launch_core1_with_stack(
        cshims_scheduler_core1_entry,
        cshims_core1_stack,
        sizeof(cshims_core1_stack));
}

uint32_t cshims_enter_critical(void) {
#if defined(__arm__) || defined(__thumb__)
    uint32_t status;
    __asm volatile(
        "mrs %0, primask\n"
        "cpsid i\n"
        : "=r"(status)
        :
        : "memory");
    return status;
#else
    return 0;
#endif
}

void cshims_exit_critical(uint32_t state) {
#if defined(__arm__) || defined(__thumb__)
    __asm volatile("msr primask, %0\n" : : "r"(state) : "memory");
#else
    (void)state;
#endif
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalImpl(void *job) {
    cshims_scheduler_enqueue_immediate(job, NULL, NULL);
}

SWIFT_CC_SWIFT void swift_task_enqueueMainExecutorImpl(void *job) {
    cshims_scheduler_enqueue_immediate(job, NULL, NULL);
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDelayImpl(uint64_t delay, void *job) {
    uint64_t delayUs = delay / 1000u;
    if (delay > 0 && delayUs == 0) {
        delayUs = 1;
    }
    cshims_scheduler_enqueue_delayed(delayUs, job, NULL, NULL);
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDeadlineImpl(
    long long sec,
    long long nsec,
    long long toleranceSec,
    long long toleranceNsec,
    int clock,
    void *job
) {
    uint64_t deadlineUs = 0;
    if (sec > 0) {
        deadlineUs = (uint64_t)sec * 1000000ull;
    }
    if (nsec > 0) {
        deadlineUs += (uint64_t)nsec / 1000ull;
    }

    (void)toleranceSec;
    (void)toleranceNsec;
    (void)clock;

    cshims_scheduler_enqueue_deadline(deadlineUs, job, NULL, NULL);
}

SWIFT_CC_SWIFT void swift_task_donateThreadToGlobalExecutorUntilImpl(
    bool (*condition)(void *),
    void *conditionContext
) {
    while (!condition(conditionContext)) {
        if (!cshims_scheduler_poll_once()) {
            cshims_scheduler_wait_for_work_forever();
        }
    }
}

SWIFT_CC_SWIFT void swift_task_checkIsolatedImpl(SwiftExecutorRef executor) {
    (void)executor;
}

SWIFT_CC_SWIFT int8_t swift_task_isIsolatingCurrentContextImpl(SwiftExecutorRef executor) {
    if (cshims_executor_is_generic(executor)) {
        return 1;
    }
    return swift_task_isCurrentExecutor(executor) ? 1 : 0;
}

SWIFT_CC_SWIFT SwiftExecutorRef swift_task_getMainExecutorImpl(void) {
    return cshims_generic_executor();
}

SWIFT_CC_SWIFT bool swift_task_isMainExecutorImpl(SwiftExecutorRef executor) {
    return cshims_executor_equal(executor, cshims_generic_executor());
}

SWIFT_NORETURN SWIFT_CC_SWIFT void swift_task_asyncMainDrainQueueImpl(void) {
    for (;;) {
        if (!cshims_scheduler_poll_once()) {
            cshims_scheduler_wait_for_work_forever();
        }
    }
}

void *swift_getObjectType(void *object) {
    if (object == NULL) {
        return NULL;
    }
    return *(void **)object;
}

bool swift_compareWitnessTables(const void *lhs, const void *rhs) {
    return lhs == rhs;
}

SwiftExecutorRef SWIFT_CC_SWIFT _task_serialExecutor_getExecutorRef(
    void *executor,
    const void *selfType,
    const void *wtable
) {
    (void)selfType;
    SwiftExecutorRef ref = {executor, (void *)wtable};
    return ref;
}

bool SWIFT_CC_SWIFT _task_serialExecutor_isSameExclusiveExecutionContext(
    void *currentExecutor,
    void *executor,
    const void *selfType,
    const void *wtable
) {
    (void)selfType;
    (void)wtable;
    return currentExecutor == executor;
}

void SWIFT_CC_SWIFT _task_serialExecutor_checkIsolated(
    void *executor,
    const void *selfType,
    const void *wtable
) {
    (void)executor;
    (void)selfType;
    (void)wtable;
}

int8_t SWIFT_CC_SWIFT _task_serialExecutor_isIsolatingCurrentContext(
    void *executor,
    const void *selfType,
    const void *wtable
) {
    SwiftExecutorRef ref = _task_serialExecutor_getExecutorRef(executor, selfType, wtable);
    return swift_task_isCurrentExecutor(ref) ? 1 : 0;
}

bool _swift_shouldReportFatalErrorsToDebugger(void) {
    return true;
}

void _swift_reportToDebugger(uintptr_t flags, const char *message, void *details) {
  // Do nothing. This function is meant to be used by the debugger.

  // The following is necessary to avoid calls from being optimized out.
  asm volatile("" // Do nothing.
               : // Output list, empty.
               : "r" (flags), "r" (message), "r" (details) // Input list.
               : // Clobber list, empty.
               );
}

int memset_s(void *dest, size_t destSize, int ch, size_t count) {
    if (dest == NULL) {
        return EINVAL;
    }

    if (count > destSize) {
        memset(dest, ch, destSize);
        return EINVAL;
    }

    memset(dest, ch, count);
    return 0;
}

extern uint64_t time_us_64(void);

int clock_gettime(clockid_t clockID, struct timespec *ts) {
    (void)clockID;
    if (ts == NULL) {
        return -1;
    }

    uint64_t nowUs = time_us_64();
    ts->tv_sec = (time_t)(nowUs / 1000000ull);
    ts->tv_nsec = (long)((nowUs % 1000000ull) * 1000ull);
    return 0;
}

int clock_getres(clockid_t clockID, struct timespec *ts) {
    (void)clockID;
    if (ts == NULL) {
        return -1;
    }

    ts->tv_sec = 0;
    ts->tv_nsec = 1000;
    return 0;
}
