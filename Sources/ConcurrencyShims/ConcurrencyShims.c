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

/* ==========================================================================
 * UNSTABLE DEBUG PROBE: cshims_task_get_name_debug
 *
 * Attempts to read the Swift task name from a raw SwiftJob pointer using
 * private runtime internals.
 *
 * VALID ONLY FOR:
 *   runtime commit : 8104e4c3ae46d1211755afa5a709f6b8624c1c79
 *   target triple  : armv7em-none-none-eabi  (32-bit, sizeof(void*)==4)
 *   config         : SWIFT_CONCURRENCY_EMBEDDED, no Dispatch,
 *                    SWIFT_CONCURRENCY_ENABLE_PRIORITY_ESCALATION=0
 *
 * Layout derivation (all offsets are byte offsets from the SwiftJob pointer):
 *
 *  AsyncTask : Job
 *  ───────────────────────────────────────────────────────────
 *  [ 0] HeapObject.metadata          void*       4 B
 *  [ 4] HeapObject.refcount          uint32_t    4 B
 *  [ 8] SchedulerPrivate[0]          void*       4 B
 *  [12] SchedulerPrivate[1]          void*       4 B
 *  [16] Flags  (JobFlags, uint32_t)              4 B
 *         bits  0-7 : JobKind (0 = task job)
 *         bit  30   : Task_HasInitialTaskName
 *  [20] Id     (uint32_t)                        4 B  ← verified in Task.h:
 *                                                        offsetof(AsyncTask,Id)
 *                                                        == 4*sizeof(void*)+4 == 20
 *  [24] Voucher                      void*       4 B
 *  [28] Reserved                     void*       4 B
 *  [32] ResumeTask/RunJob            fnptr       4 B
 *  [36] <4 B tail padding — sizeof(Job) == 40 B>
 *  [40] ResumeContext                void*       4 B
 *  [44] <4 B padding — aligns Private to 8 B>
 *
 *  [48] Private.Storage  (= PrivateStorage struct)
 *  [48]   ExclusivityAccessSet[2]    uintptr_t   4+4 B
 *  [56]   StatusStorage  (= std::atomic<ActiveTaskStatus>, alignas(8), 8 B)
 *           ActiveTaskStatus layout (no priority escalation, 32-bit):
 *  [56]     .Flags                   uint32_t    4 B  (status flags)
 *  [60]     .Record                  void*       4 B  ← innermost TaskStatusRecord*
 *  [64]   Allocator  (TaskAllocator, 2 words + 4 B)   12 B
 *  [76]   Local  (TaskLocal::Storage, 1 word)          4 B
 *  [80]   Id  (upper 32 bits of 64-bit TaskID)        4 B
 *  ...
 *
 *  TaskStatusRecord (singly-linked, from innermost outward via Parent):
 *  [ 0] Flags  (TaskStatusRecordFlags = uintptr_t)    4 B
 *         bits 0-7: kind  (6 = TaskName)
 *  [ 4] Parent                       void*            4 B
 *
 *  TaskNameStatusRecord extends TaskStatusRecord:
 *  [ 8] Name                         const char*      4 B  ← task name string
 *
 *  Source references (commit 8104e4c3ae46d1211755afa5a709f6b8624c1c79):
 *    include/swift/ABI/Task.h          — AsyncTask / Job layout, Id static_assert
 *    include/swift/ABI/TaskStatus.h    — TaskNameStatusRecord, TaskStatusRecord
 *    include/swift/ABI/MetadataValues.h— TaskStatusRecordKind::TaskName = 6,
 *                                        Task_HasInitialTaskName = bit 30
 *    stdlib/public/Concurrency/TaskPrivate.h — ActiveTaskStatus, PrivateStorage
 *    stdlib/public/Concurrency/TaskStatus.cpp — AsyncTask::getTaskName()
 * ==========================================================================*/
const char *cshims_task_get_name_debug(void *job) {
#if defined(__arm__) || defined(__thumb__)
    if (job == NULL) {
        return NULL;
    }

    /* Read JobFlags (uint32_t) at byte offset 16. */
    uint32_t jobFlags;
    __builtin_memcpy(&jobFlags, (const char *)job + 16, sizeof(jobFlags));

    /* Bits 0-7 encode the JobKind.  A value of 0 means SwiftTaskJobKind
     * (async task).  Any other kind is not a task — skip it. */
    if ((jobFlags & 0xFFu) != 0u) {
        return NULL;
    }

    /* Bit 30 = Task_HasInitialTaskName.  If clear the task has no name. */
    if (!(jobFlags & (1u << 30))) {
        return NULL;
    }

    /* Read the innermost TaskStatusRecord* from ActiveTaskStatus.Record
     * at byte offset 60:  48 (Private) + 8 (StatusStorage) + 4 (Record). */
    void *record;
    __builtin_memcpy(&record, (const char *)job + 60, sizeof(record));

    /* Walk the status record chain (Parent links) looking for kind == 6. */
    for (int depth = 0; depth < 16 && record != NULL; ++depth) {
        /* TaskStatusRecordFlags (uintptr_t) at offset 0 — kind in bits 0-7. */
        uint32_t recordFlags;
        __builtin_memcpy(&recordFlags, record, sizeof(recordFlags));

        if ((recordFlags & 0xFFu) == 6u) { /* TaskStatusRecordKind::TaskName */
            /* Name pointer is at offset 8 (= 2 pointer-words into the record). */
            const char *name = NULL;
            __builtin_memcpy(&name, (const char *)record + 8, sizeof(name));
            return name;
        }

        /* Follow the Parent link at offset 4. */
        void *parent = NULL;
        __builtin_memcpy(&parent, (const char *)record + 4, sizeof(parent));
        record = parent;
    }

    return NULL;
#else
    /* This probe is only valid on the embedded ARM target. */
    (void)job;
    return NULL;
#endif
}
