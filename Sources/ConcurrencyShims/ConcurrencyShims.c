#include "ConcurrencyShims.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <string.h>
#include <time.h>

#if defined(__clang__)
#define SWIFT_CC_SWIFT __attribute__((swiftcall))
#define SWIFT_NORETURN __attribute__((noreturn))
#else
#define SWIFT_CC_SWIFT
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

    const size_t flagsOffset = 4u * sizeof(void *);
    uint32_t flags;
    memcpy(&flags, (const char *)job + flagsOffset, sizeof(flags));

    const uint32_t jobKindMask = 0xffu;
    const uint32_t asyncTaskKind = 0u;
    const uint32_t nullaryContinuationKind = 195u;
    const uint32_t jobKind = flags & jobKindMask;
    if (jobKind == asyncTaskKind) {
        return job;
    }
    if (jobKind == nullaryContinuationKind) {
        const size_t jobBaseWords = sizeof(void *) == 4u ? 10u : 8u;
        const size_t continuationOffset = (jobBaseWords + 1u) * sizeof(void *);
        void *continuation;
        memcpy(&continuation, (const char *)job + continuationOffset, sizeof(continuation));
        return continuation;
    }
    return NULL;
}

void *cshims_current_task(void) {
    return swift_task_getCurrent();
}

static void cshims_scheduler_core1_entry(void) {
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
