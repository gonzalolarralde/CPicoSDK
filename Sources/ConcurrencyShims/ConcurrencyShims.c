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
extern bool SWIFT_CC_SWIFT swift_task_isCurrentExecutor(SwiftExecutorRef executor);

extern int cshims_scheduler_poll_once(void);
extern void cshims_scheduler_drain(void);
extern void cshims_scheduler_enqueue_immediate(void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_enqueue_delayed(uint64_t delayUs, void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_enqueue_deadline(uint64_t deadlineUs, void *job, void *executorFirst, void *executorSecond);
extern void cshims_scheduler_wait_for_work_forever(void);

static inline uint32_t cshims_save_and_disable_interrupts(void) {
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

static inline void cshims_restore_interrupts(uint32_t status) {
#if defined(__arm__) || defined(__thumb__)
    __asm volatile("msr primask, %0\n" : : "r"(status) : "memory");
#else
    (void)status;
#endif
}

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

int cshims_swift_task_poll_once(void) {
    return cshims_scheduler_poll_once();
}

void cshims_swift_task_drain(void) {
    cshims_scheduler_drain();
}

void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond) {
    swift_job_run(job, executorFirst, executorSecond);
}

uint32_t cshims_enter_critical(void) {
    return cshims_save_and_disable_interrupts();
}

void cshims_exit_critical(uint32_t state) {
    cshims_restore_interrupts(state);
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
    return false;
}

void _swift_reportToDebugger(uintptr_t flags, const char *message, void *details) {
    (void)flags;
    (void)message;
    (void)details;
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

// ============================================================================
// Task name extraction from SwiftJob* (debug/experimental)
// ============================================================================
//
// UNSTABLE ABI WARNING
// --------------------
// Everything in this section depends on Swift runtime internals that are NOT
// part of the stable public ABI.  The kind constant and symbol names below
// were verified against the main-snapshot-2026-04-01 embedded runtime
// (libswift_Concurrency.a, armv7em-none-none-eabi).  They can change in any
// future Swift release without notice.
//
// Use these helpers only for debug diagnostics and experimental tooling.
// Do not rely on their output in production firmware.
//
// See Docs/TASK_NAME_EXTRACTION.md for the full investigation notes,
// memory-layout diagrams, and guidance for callers.
// ============================================================================

// swift_job_getKind
//   Exported as a plain C symbol from libswift_Concurrency.a.
//   Returns the JobKind value for a job:
//     0 = Unknown / non-task work item
//     1 = Task    (Swift AsyncTask — has a name field)
//     2 = JobDispatch (non-task enqueued work item)
//   Source: stdlib/public/Concurrency/JobFlags.h
extern SWIFT_CC_SWIFT uint32_t swift_job_getKind(const void *job);

// swift_task_getTaskName
//   Returns the debug name of an AsyncTask as a C string, or NULL if the task
//   was created without a name.  Available in Swift 5.9+ runtimes.
//
//   In embedded builds this function is exported only under its C++ mangled
//   symbol name:
//     _Z22swift_task_getTaskNamePN5swift9AsyncTaskE
//   (i.e. swift_task_getTaskName(swift::AsyncTask*))
//
//   We reach it from C via the __asm__ linkage-name attribute, which is a
//   Clang/GCC extension that redirects the symbol lookup at link time without
//   changing the calling convention.  The SWIFT_CC_SWIFT attribute matches the
//   function's swiftcall ABI; on ARMv7-EM, swiftcall is identical to the C
//   calling convention for a single pointer argument and pointer return value,
//   so the call is safe in practice.
#if defined(__clang__)
extern SWIFT_CC_SWIFT const char *cshims_swift_task_getTaskName_impl(const void *task)
    __asm__("_Z22swift_task_getTaskNamePN5swift9AsyncTaskE");
#endif

// swift_task_getCurrentTaskName
//   Plain C export.  Returns the name of the task that is currently executing
//   on this thread (the name that the runtime stores in its thread-local
//   current-task slot).  Only valid when called from inside a job callback
//   (e.g. after swift_job_run has been entered).  Returns NULL if the running
//   job is not a named task.
extern SWIFT_CC_SWIFT const char *swift_task_getCurrentTaskName(void);

// JobKind constant — Task is kind 1 across Swift 5.9+ releases.
#define CSHIMS_JOB_KIND_TASK 1u

// cshims_job_is_task
//   Returns true if `job` is an AsyncTask (Swift Task infrastructure), false
//   for NULL, non-task work items, or any job whose kind cannot be read.
bool cshims_job_is_task(const void *job) {
    if (job == NULL) return false;
    return swift_job_getKind(job) == CSHIMS_JOB_KIND_TASK;
}

// cshims_job_get_task_name
//   Returns the debug name of the AsyncTask associated with `job`, or NULL if:
//     - job is NULL or is not an AsyncTask
//     - the task was created without a name (Task { } rather than Task(name:) { })
//     - the runtime was compiled in a configuration that omits name metadata
//     - the compiler in use is not Clang (the __asm__ linkage trick is
//       Clang/GCC-specific)
//
//   The returned pointer is owned by the runtime and valid for the lifetime of
//   the task.  The caller must not free it.
//
//   Intended for debug logging only.  Do not use in production code paths.
const char *cshims_job_get_task_name(const void *job) {
    if (!cshims_job_is_task(job)) return NULL;
#if defined(__clang__)
    // Reach the C++-mangled swift_task_getTaskName via its ARM/Thumb symbol.
    return cshims_swift_task_getTaskName_impl(job);
#else
    return NULL;
#endif
}
