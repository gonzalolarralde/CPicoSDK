#include "ConcurrencyShims.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
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

typedef struct {
    void *first;
    void *second;
} SwiftExecutorRef;

typedef uint64_t absolute_time_t;
typedef volatile uint8_t spin_lock_t;

typedef struct {
    spin_lock_t *spin_lock;
} lock_core_t;

typedef struct {
    lock_core_t core;
    int16_t permits;
    int16_t max_permits;
} semaphore_t;

typedef struct async_context async_context_t;

typedef struct async_at_time_worker {
    struct async_at_time_worker *next;
    void (*do_work)(async_context_t *context, struct async_at_time_worker *worker);
    absolute_time_t next_time;
    void *user_data;
} async_at_time_worker_t;

typedef struct async_when_pending_worker {
    struct async_when_pending_worker *next;
    void (*do_work)(async_context_t *context, struct async_when_pending_worker *worker);
    bool work_pending;
    void *user_data;
} async_when_pending_worker_t;

typedef struct async_context_type {
    uint16_t type;
    void (*acquire_lock_blocking)(async_context_t *self);
    void (*release_lock)(async_context_t *self);
    void (*lock_check)(async_context_t *self);
    uint32_t (*execute_sync)(async_context_t *context, uint32_t (*func)(void *param), void *param);
    bool (*add_at_time_worker)(async_context_t *self, async_at_time_worker_t *worker);
    bool (*remove_at_time_worker)(async_context_t *self, async_at_time_worker_t *worker);
    bool (*add_when_pending_worker)(async_context_t *self, async_when_pending_worker_t *worker);
    bool (*remove_when_pending_worker)(async_context_t *self, async_when_pending_worker_t *worker);
    void (*set_work_pending)(async_context_t *self, async_when_pending_worker_t *worker);
    void (*poll)(async_context_t *self);
    void (*wait_until)(async_context_t *self, absolute_time_t until);
    void (*wait_for_work_until)(async_context_t *self, absolute_time_t until);
    void (*deinit)(async_context_t *self);
} async_context_type_t;

struct async_context {
    const async_context_type_t *type;
    async_when_pending_worker_t *when_pending_list;
    async_at_time_worker_t *at_time_list;
    absolute_time_t next_time;
    uint16_t flags;
    uint8_t core_num;
};

typedef struct {
    async_context_t core;
    semaphore_t sem;
} async_context_poll_t;

typedef enum {
    CSHIMS_JOB_SLOT_FREE = 0,
    CSHIMS_JOB_SLOT_PENDING = 1,
    CSHIMS_JOB_SLOT_DELAYED = 2,
} cshims_job_slot_state_t;

typedef struct {
    cshims_job_slot_state_t state;
    void *job;
    SwiftExecutorRef executor;
    async_when_pending_worker_t pending_worker;
    async_at_time_worker_t delayed_worker;
} cshims_job_slot_t;

extern void SWIFT_CC_SWIFT swift_job_run(void *job, void *executorFirst, void *executorSecond);
extern bool SWIFT_CC_SWIFT swift_task_isCurrentExecutor(SwiftExecutorRef executor);
extern uint64_t time_us_64(void);
extern bool async_context_poll_init_with_defaults(async_context_poll_t *self);

enum { CSHIMS_MAX_JOB_SLOTS = 64 };

static async_context_poll_t gAsyncContextPoll;
static async_context_t *gAsyncContext = NULL;
static bool gAsyncContextInitialized = false;
static volatile uint8_t gDidRunJob = 0;
static cshims_job_slot_t gJobSlots[CSHIMS_MAX_JOB_SLOTS];

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

static absolute_time_t cshims_nil_time(void) {
    return 0;
}

static absolute_time_t cshims_at_the_end_of_time(void) {
    return UINT64_MAX;
}

static absolute_time_t cshims_make_timeout_time_us(uint64_t us) {
    return time_us_64() + us;
}

static void cshims_async_context_poll(async_context_t *context) {
    if (context->type->poll) {
        context->type->poll(context);
    }
}

static bool cshims_async_context_add_when_pending_worker(async_context_t *context, async_when_pending_worker_t *worker) {
    return context->type->add_when_pending_worker(context, worker);
}

static void cshims_async_context_set_work_pending(async_context_t *context, async_when_pending_worker_t *worker) {
    context->type->set_work_pending(context, worker);
}

static bool cshims_async_context_add_at_time_worker_at(async_context_t *context, async_at_time_worker_t *worker, absolute_time_t at) {
    worker->next_time = at;
    return context->type->add_at_time_worker(context, worker);
}

static void cshims_async_context_wait_for_work_until(async_context_t *context, absolute_time_t until) {
    context->type->wait_for_work_until(context, until);
}

static void cshims_release_slot(cshims_job_slot_t *slot) {
    uint32_t status = cshims_save_and_disable_interrupts();
    slot->state = CSHIMS_JOB_SLOT_FREE;
    slot->job = NULL;
    slot->executor = cshims_generic_executor();
    cshims_restore_interrupts(status);
}

static void cshims_run_job_from_slot(cshims_job_slot_t *slot) {
    void *job = slot->job;
    SwiftExecutorRef executor = slot->executor;
    cshims_release_slot(slot);
    gDidRunJob = 1;
    swift_job_run(job, executor.first, executor.second);
}

static void cshims_do_pending_job(async_context_t *context, async_when_pending_worker_t *worker) {
    (void)context;
    cshims_job_slot_t *slot = (cshims_job_slot_t *)worker->user_data;
    cshims_run_job_from_slot(slot);
}

static void cshims_do_delayed_job(async_context_t *context, async_at_time_worker_t *worker) {
    (void)context;
    cshims_job_slot_t *slot = (cshims_job_slot_t *)worker->user_data;
    cshims_run_job_from_slot(slot);
}

static async_context_t *cshims_context(void) {
    if (gAsyncContextInitialized) {
        return gAsyncContext;
    }

    if (!async_context_poll_init_with_defaults(&gAsyncContextPoll)) {
        fputs("[CPicoSDK] async_context_poll_init_with_defaults failed\n", stderr);
        abort();
    }

    gAsyncContext = &gAsyncContextPoll.core;

    for (size_t i = 0; i < CSHIMS_MAX_JOB_SLOTS; ++i) {
        cshims_job_slot_t *slot = &gJobSlots[i];
        slot->state = CSHIMS_JOB_SLOT_FREE;
        slot->job = NULL;
        slot->executor = cshims_generic_executor();
        slot->pending_worker.next = NULL;
        slot->pending_worker.do_work = cshims_do_pending_job;
        slot->pending_worker.work_pending = false;
        slot->pending_worker.user_data = slot;
        slot->delayed_worker.next = NULL;
        slot->delayed_worker.do_work = cshims_do_delayed_job;
        slot->delayed_worker.next_time = cshims_nil_time();
        slot->delayed_worker.user_data = slot;

        if (!cshims_async_context_add_when_pending_worker(gAsyncContext, &slot->pending_worker)) {
            fputs("[CPicoSDK] failed to register pending worker with async_context\n", stderr);
            abort();
        }
    }

    gAsyncContextInitialized = true;
    return gAsyncContext;
}

static cshims_job_slot_t *cshims_allocate_slot_or_die(const char *where) {
    uint32_t status = cshims_save_and_disable_interrupts();
    for (size_t i = 0; i < CSHIMS_MAX_JOB_SLOTS; ++i) {
        cshims_job_slot_t *slot = &gJobSlots[i];
        if (slot->state == CSHIMS_JOB_SLOT_FREE) {
            slot->state = CSHIMS_JOB_SLOT_PENDING;
            slot->job = NULL;
            slot->executor = cshims_generic_executor();
            slot->pending_worker.work_pending = false;
            slot->delayed_worker.next = NULL;
            slot->delayed_worker.next_time = cshims_nil_time();
            cshims_restore_interrupts(status);
            return slot;
        }
    }
    cshims_restore_interrupts(status);

    fputs("[CPicoSDK] Concurrency job slot pool exhausted in ", stderr);
    fputs(where, stderr);
    fputs("\n", stderr);
    abort();
}

static void cshims_enqueue_pending_or_die(void *job, SwiftExecutorRef executor, const char *where) {
    async_context_t *context = cshims_context();
    cshims_job_slot_t *slot = cshims_allocate_slot_or_die(where);
    slot->state = CSHIMS_JOB_SLOT_PENDING;
    slot->job = job;
    slot->executor = executor;
    cshims_async_context_set_work_pending(context, &slot->pending_worker);
}

static void cshims_enqueue_delayed_or_die(void *job, SwiftExecutorRef executor, absolute_time_t when, const char *where) {
    async_context_t *context = cshims_context();
    cshims_job_slot_t *slot = cshims_allocate_slot_or_die(where);
    slot->state = CSHIMS_JOB_SLOT_DELAYED;
    slot->job = job;
    slot->executor = executor;
    slot->delayed_worker.next_time = when;

    if (!cshims_async_context_add_at_time_worker_at(context, &slot->delayed_worker, when)) {
        cshims_release_slot(slot);
        fputs("[CPicoSDK] Failed to schedule delayed job in ", stderr);
        fputs(where, stderr);
        fputs("\n", stderr);
        abort();
    }
}

void swift_createDefaultExecutors(void) {}

int cshims_swift_task_poll_once(void) {
    async_context_t *context = cshims_context();
    gDidRunJob = 0;
    cshims_async_context_poll(context);
    return gDidRunJob ? 1 : 0;
}

void cshims_swift_task_drain(void) {
    while (cshims_swift_task_poll_once()) {
    }
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalImpl(void *job) {
    cshims_enqueue_pending_or_die(job, cshims_generic_executor(), "swift_task_enqueueGlobalImpl");
}

SWIFT_CC_SWIFT void swift_task_enqueueMainExecutorImpl(void *job) {
    cshims_enqueue_pending_or_die(job, cshims_generic_executor(), "swift_task_enqueueMainExecutorImpl");
}

SWIFT_CC_SWIFT void swift_task_enqueueGlobalWithDelayImpl(uint64_t delay, void *job) {
    uint64_t delayUs = delay / 1000u;
    if (delay > 0 && delayUs == 0) {
        delayUs = 1;
    }
    cshims_enqueue_delayed_or_die(
        job,
        cshims_generic_executor(),
        cshims_make_timeout_time_us(delayUs),
        "swift_task_enqueueGlobalWithDelayImpl"
    );
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

    cshims_enqueue_delayed_or_die(
        job,
        cshims_generic_executor(),
        deadlineUs,
        "swift_task_enqueueGlobalWithDeadlineImpl"
    );
}

SWIFT_CC_SWIFT void swift_task_donateThreadToGlobalExecutorUntilImpl(
    bool (*condition)(void *),
    void *conditionContext
) {
    async_context_t *context = cshims_context();
    while (!condition(conditionContext)) {
        if (!cshims_swift_task_poll_once()) {
            cshims_async_context_wait_for_work_until(context, cshims_at_the_end_of_time());
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
    async_context_t *context = cshims_context();
    for (;;) {
        if (!cshims_swift_task_poll_once()) {
            cshims_async_context_wait_for_work_until(context, cshims_at_the_end_of_time());
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
