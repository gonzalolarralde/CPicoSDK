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

static cshims_irq_handler_t cshims_irq_wrapper_originals[64] = {0};

void cshims_set_irq_wrapper_original(unsigned int irq, cshims_irq_handler_t handler) {
    const size_t count = sizeof(cshims_irq_wrapper_originals) / sizeof(cshims_irq_wrapper_originals[0]);
    if (irq >= count) {
        return;
    }
    cshims_irq_wrapper_originals[irq] = handler;
}

static void cshims_irq_wrapper_dispatch(uint32_t irq) {
    const size_t count = sizeof(cshims_irq_wrapper_originals) / sizeof(cshims_irq_wrapper_originals[0]);
    if (irq >= count) {
        return;
    }

    cshims_irq_handler_t original = cshims_irq_wrapper_originals[irq];
    if (original != NULL) {
        original();
    }
}

#define CSHIMS_DEFINE_IRQ_WRAPPER(N) \
    static void cshims_irq_wrapper_##N(void) { cshims_irq_wrapper_dispatch(N); }

CSHIMS_DEFINE_IRQ_WRAPPER(0)
CSHIMS_DEFINE_IRQ_WRAPPER(1)
CSHIMS_DEFINE_IRQ_WRAPPER(2)
CSHIMS_DEFINE_IRQ_WRAPPER(3)
CSHIMS_DEFINE_IRQ_WRAPPER(4)
CSHIMS_DEFINE_IRQ_WRAPPER(5)
CSHIMS_DEFINE_IRQ_WRAPPER(6)
CSHIMS_DEFINE_IRQ_WRAPPER(7)
CSHIMS_DEFINE_IRQ_WRAPPER(8)
CSHIMS_DEFINE_IRQ_WRAPPER(9)
CSHIMS_DEFINE_IRQ_WRAPPER(10)
CSHIMS_DEFINE_IRQ_WRAPPER(11)
CSHIMS_DEFINE_IRQ_WRAPPER(12)
CSHIMS_DEFINE_IRQ_WRAPPER(13)
CSHIMS_DEFINE_IRQ_WRAPPER(14)
CSHIMS_DEFINE_IRQ_WRAPPER(15)
CSHIMS_DEFINE_IRQ_WRAPPER(16)
CSHIMS_DEFINE_IRQ_WRAPPER(17)
CSHIMS_DEFINE_IRQ_WRAPPER(18)
CSHIMS_DEFINE_IRQ_WRAPPER(19)
CSHIMS_DEFINE_IRQ_WRAPPER(20)
CSHIMS_DEFINE_IRQ_WRAPPER(21)
CSHIMS_DEFINE_IRQ_WRAPPER(22)
CSHIMS_DEFINE_IRQ_WRAPPER(23)
CSHIMS_DEFINE_IRQ_WRAPPER(24)
CSHIMS_DEFINE_IRQ_WRAPPER(25)
CSHIMS_DEFINE_IRQ_WRAPPER(26)
CSHIMS_DEFINE_IRQ_WRAPPER(27)
CSHIMS_DEFINE_IRQ_WRAPPER(28)
CSHIMS_DEFINE_IRQ_WRAPPER(29)
CSHIMS_DEFINE_IRQ_WRAPPER(30)
CSHIMS_DEFINE_IRQ_WRAPPER(31)
CSHIMS_DEFINE_IRQ_WRAPPER(32)
CSHIMS_DEFINE_IRQ_WRAPPER(33)
CSHIMS_DEFINE_IRQ_WRAPPER(34)
CSHIMS_DEFINE_IRQ_WRAPPER(35)
CSHIMS_DEFINE_IRQ_WRAPPER(36)
CSHIMS_DEFINE_IRQ_WRAPPER(37)
CSHIMS_DEFINE_IRQ_WRAPPER(38)
CSHIMS_DEFINE_IRQ_WRAPPER(39)
CSHIMS_DEFINE_IRQ_WRAPPER(40)
CSHIMS_DEFINE_IRQ_WRAPPER(41)
CSHIMS_DEFINE_IRQ_WRAPPER(42)
CSHIMS_DEFINE_IRQ_WRAPPER(43)
CSHIMS_DEFINE_IRQ_WRAPPER(44)
CSHIMS_DEFINE_IRQ_WRAPPER(45)
CSHIMS_DEFINE_IRQ_WRAPPER(46)
CSHIMS_DEFINE_IRQ_WRAPPER(47)
CSHIMS_DEFINE_IRQ_WRAPPER(48)
CSHIMS_DEFINE_IRQ_WRAPPER(49)
CSHIMS_DEFINE_IRQ_WRAPPER(50)
CSHIMS_DEFINE_IRQ_WRAPPER(51)
CSHIMS_DEFINE_IRQ_WRAPPER(52)
CSHIMS_DEFINE_IRQ_WRAPPER(53)
CSHIMS_DEFINE_IRQ_WRAPPER(54)
CSHIMS_DEFINE_IRQ_WRAPPER(55)
CSHIMS_DEFINE_IRQ_WRAPPER(56)
CSHIMS_DEFINE_IRQ_WRAPPER(57)
CSHIMS_DEFINE_IRQ_WRAPPER(58)
CSHIMS_DEFINE_IRQ_WRAPPER(59)
CSHIMS_DEFINE_IRQ_WRAPPER(60)
CSHIMS_DEFINE_IRQ_WRAPPER(61)
CSHIMS_DEFINE_IRQ_WRAPPER(62)
CSHIMS_DEFINE_IRQ_WRAPPER(63)

static cshims_irq_handler_t cshims_irq_wrappers[] = {
    cshims_irq_wrapper_0,
    cshims_irq_wrapper_1,
    cshims_irq_wrapper_2,
    cshims_irq_wrapper_3,
    cshims_irq_wrapper_4,
    cshims_irq_wrapper_5,
    cshims_irq_wrapper_6,
    cshims_irq_wrapper_7,
    cshims_irq_wrapper_8,
    cshims_irq_wrapper_9,
    cshims_irq_wrapper_10,
    cshims_irq_wrapper_11,
    cshims_irq_wrapper_12,
    cshims_irq_wrapper_13,
    cshims_irq_wrapper_14,
    cshims_irq_wrapper_15,
    cshims_irq_wrapper_16,
    cshims_irq_wrapper_17,
    cshims_irq_wrapper_18,
    cshims_irq_wrapper_19,
    cshims_irq_wrapper_20,
    cshims_irq_wrapper_21,
    cshims_irq_wrapper_22,
    cshims_irq_wrapper_23,
    cshims_irq_wrapper_24,
    cshims_irq_wrapper_25,
    cshims_irq_wrapper_26,
    cshims_irq_wrapper_27,
    cshims_irq_wrapper_28,
    cshims_irq_wrapper_29,
    cshims_irq_wrapper_30,
    cshims_irq_wrapper_31,
    cshims_irq_wrapper_32,
    cshims_irq_wrapper_33,
    cshims_irq_wrapper_34,
    cshims_irq_wrapper_35,
    cshims_irq_wrapper_36,
    cshims_irq_wrapper_37,
    cshims_irq_wrapper_38,
    cshims_irq_wrapper_39,
    cshims_irq_wrapper_40,
    cshims_irq_wrapper_41,
    cshims_irq_wrapper_42,
    cshims_irq_wrapper_43,
    cshims_irq_wrapper_44,
    cshims_irq_wrapper_45,
    cshims_irq_wrapper_46,
    cshims_irq_wrapper_47,
    cshims_irq_wrapper_48,
    cshims_irq_wrapper_49,
    cshims_irq_wrapper_50,
    cshims_irq_wrapper_51,
    cshims_irq_wrapper_52,
    cshims_irq_wrapper_53,
    cshims_irq_wrapper_54,
    cshims_irq_wrapper_55,
    cshims_irq_wrapper_56,
    cshims_irq_wrapper_57,
    cshims_irq_wrapper_58,
    cshims_irq_wrapper_59,
    cshims_irq_wrapper_60,
    cshims_irq_wrapper_61,
    cshims_irq_wrapper_62,
    cshims_irq_wrapper_63,
};

cshims_irq_handler_t cshims_get_irq_wrapper(unsigned int irq) {
    const size_t wrapperCount = sizeof(cshims_irq_wrappers) / sizeof(cshims_irq_wrappers[0]);
    if (irq >= wrapperCount) {
        return NULL;
    }
    return cshims_irq_wrappers[irq];
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

void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond) {
    swift_job_run(job, executorFirst, executorSecond);
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
