#include "ConcurrencyShims.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__clang__)
#define SWIFT_CC_SWIFT __attribute__((swiftcall))
#define SWIFT_NORETURN __attribute__((noreturn))
#else
#define SWIFT_CC_SWIFT
#define SWIFT_NORETURN
#endif

static inline void cshims_wait_for_event(void) {
    __asm volatile("wfe" ::: "memory");
}

static inline uint32_t cshims_save_and_disable_interrupts(void) {
    uint32_t status;
    __asm volatile(
        "mrs %0, primask\n"
        "cpsid i\n"
        : "=r"(status)
        :
        : "memory");
    return status;
}

static inline void cshims_restore_interrupts(uint32_t status) {
    __asm volatile("msr primask, %0\n" : : "r"(status) : "memory");
}

typedef struct {
    void *first;
    void *second;
} SwiftExecutorRef;

typedef struct {
    void *job;
    SwiftExecutorRef executor;
} QueuedJob;

typedef struct timespec cshims_timespec_t;

extern void SWIFT_CC_SWIFT swift_job_run(void *job, void *executorFirst, void *executorSecond);
extern bool SWIFT_CC_SWIFT swift_task_isCurrentExecutor(SwiftExecutorRef executor);
extern uint64_t time_us_64(void);

enum { CSHIMS_QUEUE_CAPACITY = 64 };

static QueuedJob gQueue[CSHIMS_QUEUE_CAPACITY];
static volatile size_t gQueueHead = 0;
static volatile size_t gQueueTail = 0;

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

static bool cshims_queue_push(void *job, SwiftExecutorRef executor) {
    uint32_t status = cshims_save_and_disable_interrupts();
    size_t nextTail = (gQueueTail + 1u) % CSHIMS_QUEUE_CAPACITY;

    if (nextTail == gQueueHead) {
        cshims_restore_interrupts(status);
        return false;
    }

    gQueue[gQueueTail].job = job;
    gQueue[gQueueTail].executor = executor;
    gQueueTail = nextTail;
    cshims_restore_interrupts(status);
    return true;
}

static bool cshims_queue_pop(QueuedJob *outJob) {
    uint32_t status = cshims_save_and_disable_interrupts();

    if (gQueueHead == gQueueTail) {
        cshims_restore_interrupts(status);
        return false;
    }

    *outJob = gQueue[gQueueHead];
    gQueueHead = (gQueueHead + 1u) % CSHIMS_QUEUE_CAPACITY;
    cshims_restore_interrupts(status);
    return true;
}

static void cshims_run_job(void *job, SwiftExecutorRef executor) {
    swift_job_run(job, executor.first, executor.second);
}

int cshims_swift_task_poll_once(void) {
    QueuedJob next;
    if (!cshims_queue_pop(&next)) {
        return 0;
    }

    cshims_run_job(next.job, next.executor);
    return 1;
}

void cshims_swift_task_drain(void) {
    while (cshims_swift_task_poll_once()) {
    }
}

static void cshims_enqueue_or_die(void *job, SwiftExecutorRef executor, const char *where) {
    if (cshims_queue_push(job, executor)) {
        return;
    }

    fputs("[CPicoSDK] Concurrency queue overflow in ", stderr);
    fputs(where, stderr);
    fputs("\n", stderr);
    abort();
}

void swift_createDefaultExecutors(void) {}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalImpl(void *job) {
    cshims_enqueue_or_die(job, cshims_generic_executor(), "swift_task_enqueueGlobalImpl");
}

SWIFT_CC_SWIFT void swift_task_enqueueMainExecutorImpl(void *job) {
    cshims_enqueue_or_die(job, cshims_generic_executor(), "swift_task_enqueueMainExecutorImpl");
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDelayImpl(uint64_t delay, void *job) {
    (void)delay;
    cshims_enqueue_or_die(job, cshims_generic_executor(), "swift_task_enqueueGlobalWithDelayImpl");
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDeadlineImpl(
    long long sec,
    long long nsec,
    long long toleranceSec,
    long long toleranceNsec,
    int clock,
    void *job
) {
    (void)sec;
    (void)nsec;
    (void)toleranceSec;
    (void)toleranceNsec;
    (void)clock;
    cshims_enqueue_or_die(job, cshims_generic_executor(), "swift_task_enqueueGlobalWithDeadlineImpl");
}

SWIFT_CC_SWIFT void swift_task_donateThreadToGlobalExecutorUntilImpl(
    bool (*condition)(void *),
    void *conditionContext
) {
    while (!condition(conditionContext)) {
        if (!cshims_swift_task_poll_once()) {
            cshims_wait_for_event();
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
        if (!cshims_swift_task_poll_once()) {
            cshims_wait_for_event();
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
    return false;
}

void _swift_reportToDebugger(uintptr_t flags, const char *message, void *details) {
    (void)flags;
    (void)message;
    (void)details;
}

int memset_s(void *dest, size_t destSize, int ch, size_t count) {
    if (dest == NULL) {
        return 22; // EINVAL
    }

    if (count > destSize) {
        memset(dest, ch, destSize);
        return 22; // EINVAL
    }

    memset(dest, ch, count);
    return 0;
}

int clock_gettime(clockid_t clockID, cshims_timespec_t *ts) {
    (void)clockID;
    if (ts == NULL) {
        return -1;
    }

    uint64_t nowUs = time_us_64();
    ts->tv_sec = (time_t)(nowUs / 1000000ull);
    ts->tv_nsec = (long)((nowUs % 1000000ull) * 1000ull);
    return 0;
}

int clock_getres(clockid_t clockID, cshims_timespec_t *ts) {
    (void)clockID;
    if (ts == NULL) {
        return -1;
    }

    ts->tv_sec = 0;
    ts->tv_nsec = 1000;
    return 0;
}
