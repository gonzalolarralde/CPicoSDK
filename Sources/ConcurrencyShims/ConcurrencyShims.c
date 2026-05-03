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
extern void *SWIFT_CC_SWIFT cshims_swift_task_set_current(void *task) __asm__("_ZN5swift22_swift_task_setCurrentEPNS_9AsyncTaskE");
extern void *SWIFT_CC_SWIFT cshims_swift_task_clear_current(void) __asm__("_ZN5swift24_swift_task_clearCurrentEv");
extern const void *cshims_swift_task_heap_metadata_ptr __asm__("_ZN5swift19taskHeapMetadataPtrE");
extern void *__real_malloc(size_t size);
extern void __real_free(void *ptr);

struct _reent;

static volatile uint32_t cshims_malloc_lock_word = 0;
static volatile uint32_t cshims_malloc_lock_owner = 0;
static volatile uint32_t cshims_malloc_lock_depth[2] = {0, 0};
static volatile uint32_t cshims_malloc_lock_irq_state[2] = {0, 0};

static unsigned int cshims_core_num(void);

static uint32_t cshims_save_and_disable_interrupts(void) {
#if defined(__arm__) || defined(__thumb__)
    uint32_t state;
    __asm volatile("mrs %0, primask\ncpsid i" : "=r"(state) :: "memory");
    return state;
#else
    return 0;
#endif
}

static void cshims_restore_interrupts(uint32_t state) {
#if defined(__arm__) || defined(__thumb__)
    __asm volatile("msr primask, %0" :: "r"(state) : "memory");
#else
    (void)state;
#endif
}

void __malloc_lock(struct _reent *reent) {
    (void)reent;
    unsigned int core = cshims_core_num() & 1u;
    uint32_t owner = core + 1u;

    if (__atomic_load_n(&cshims_malloc_lock_owner, __ATOMIC_RELAXED) == owner) {
        cshims_malloc_lock_depth[core]++;
        return;
    }

    uint32_t irq_state = cshims_save_and_disable_interrupts();
    while (__atomic_exchange_n(&cshims_malloc_lock_word, 1u, __ATOMIC_ACQUIRE) != 0u) {
        __asm volatile("nop");
    }

    cshims_malloc_lock_irq_state[core] = irq_state;
    cshims_malloc_lock_depth[core] = 1u;
    __atomic_store_n(&cshims_malloc_lock_owner, owner, __ATOMIC_RELEASE);
}

void __malloc_unlock(struct _reent *reent) {
    (void)reent;
    unsigned int core = cshims_core_num() & 1u;
    uint32_t owner = core + 1u;

    if (__atomic_load_n(&cshims_malloc_lock_owner, __ATOMIC_RELAXED) != owner) {
        return;
    }

    uint32_t depth = cshims_malloc_lock_depth[core];
    if (depth > 1u) {
        cshims_malloc_lock_depth[core] = depth - 1u;
        return;
    }

    uint32_t irq_state = cshims_malloc_lock_irq_state[core];
    cshims_malloc_lock_depth[core] = 0u;
    __atomic_store_n(&cshims_malloc_lock_owner, 0u, __ATOMIC_RELEASE);
    __atomic_store_n(&cshims_malloc_lock_word, 0u, __ATOMIC_RELEASE);
    cshims_restore_interrupts(irq_state);
}

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

#define CSHIMS_CORE1_STACK_WORDS 8192

static uint32_t cshims_core1_stack[CSHIMS_CORE1_STACK_WORDS] __attribute__((aligned(8)));
static uint32_t cshims_tls_probe_core1_stack[512] __attribute__((aligned(8)));
extern char __StackBottom;
extern char __StackTop;

static volatile uint32_t cshims_tls_probe_done;
static volatile uintptr_t cshims_tls_probe_core1_before;
static volatile uintptr_t cshims_tls_probe_core1_after;
static volatile uint32_t cshims_threading_probe_done;
static volatile uintptr_t cshims_threading_probe_core1_thread_id;
static volatile uint32_t cshims_threading_probe_core1_is_main;
static volatile uintptr_t cshims_threading_probe_core1_slot0_before;
static volatile uintptr_t cshims_threading_probe_core1_slot0_after;
static volatile uintptr_t cshims_threading_probe_core1_slot1_before;
static volatile uintptr_t cshims_threading_probe_core1_slot1_after;
static volatile uintptr_t cshims_threading_probe_core1_stack_low;
static volatile uintptr_t cshims_threading_probe_core1_stack_high;

static void cshims_core1_idle_pause(void) {
#if defined(__arm__) || defined(__thumb__)
    __asm volatile("yield");
#else
    __asm volatile("" ::: "memory");
#endif
}

static void cshims_core1_idle_delay(unsigned int iterations) {
    for (unsigned int i = 0; i < iterations; i++) {
        cshims_core1_idle_pause();
    }
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

static unsigned int cshims_core_index(void) {
    return cshims_core_num() & 1u;
}

#define CSHIMS_SWIFT_TLS_SLOT_COUNT 16u

static void *cshims_swift_tls_slots[2][CSHIMS_SWIFT_TLS_SLOT_COUNT];

uintptr_t swift_threading_defer_current_thread_id(void) {
    return (uintptr_t)cshims_core_index() + 1u;
}

bool swift_threading_defer_is_main_thread(void) {
    return cshims_core_index() == 0u;
}

bool swift_threading_defer_current_stack_bounds(void **low, void **high) {
    if (low == NULL || high == NULL) {
        return false;
    }

    uintptr_t sp;
#if defined(__arm__) || defined(__thumb__)
    __asm volatile("mov %0, sp" : "=r"(sp));
#else
    sp = 0;
#endif

    uintptr_t core1Low = (uintptr_t)cshims_core1_stack;
    uintptr_t core1High = core1Low + sizeof(cshims_core1_stack);
    uintptr_t probeLow = (uintptr_t)cshims_tls_probe_core1_stack;
    uintptr_t probeHigh = probeLow + sizeof(cshims_tls_probe_core1_stack);

    if (sp >= core1Low && sp <= core1High) {
        *low = (void *)core1Low;
        *high = (void *)core1High;
        return true;
    }

    if (sp >= probeLow && sp <= probeHigh) {
        *low = (void *)probeLow;
        *high = (void *)probeHigh;
        return true;
    }

    if (cshims_core_index() == 0u) {
        *low = &__StackBottom;
        *high = &__StackTop;
        return true;
    }

    return false;
}

void swift_threading_defer_mutex_init(uintptr_t *handle, bool checked) {
    (void)checked;
    __atomic_store_n(handle, 0, __ATOMIC_RELAXED);
}

void swift_threading_defer_mutex_destroy(uintptr_t *handle) {
    (void)handle;
}

void swift_threading_defer_mutex_lock(uintptr_t *handle) {
    while (__atomic_exchange_n(handle, 1, __ATOMIC_ACQUIRE) != 0) {
        cshims_core1_idle_pause();
    }
}

void swift_threading_defer_mutex_unlock(uintptr_t *handle) {
    __atomic_store_n(handle, 0, __ATOMIC_RELEASE);
}

bool swift_threading_defer_mutex_try_lock(uintptr_t *handle) {
    uintptr_t expected = 0;
    return __atomic_compare_exchange_n(handle, &expected, 1, false,
                                       __ATOMIC_ACQUIRE, __ATOMIC_RELAXED);
}

enum {
    CSHIMS_DEFER_RECURSIVE_LOCK = 0,
    CSHIMS_DEFER_RECURSIVE_OWNER = 1,
    CSHIMS_DEFER_RECURSIVE_COUNT = 2,
    CSHIMS_DEFER_RECURSIVE_CHECKED = 3
};

void swift_threading_defer_recursive_mutex_init(uintptr_t *storage, bool checked) {
    __atomic_store_n(&storage[CSHIMS_DEFER_RECURSIVE_LOCK], 0, __ATOMIC_RELAXED);
    storage[CSHIMS_DEFER_RECURSIVE_OWNER] = 0;
    storage[CSHIMS_DEFER_RECURSIVE_COUNT] = 0;
    storage[CSHIMS_DEFER_RECURSIVE_CHECKED] = checked ? 1u : 0u;
}

void swift_threading_defer_recursive_mutex_destroy(uintptr_t *storage) {
    (void)storage;
}

void swift_threading_defer_recursive_mutex_lock(uintptr_t *storage) {
    uintptr_t current = swift_threading_defer_current_thread_id();
    if (storage[CSHIMS_DEFER_RECURSIVE_COUNT] != 0 &&
        storage[CSHIMS_DEFER_RECURSIVE_OWNER] == current) {
        storage[CSHIMS_DEFER_RECURSIVE_COUNT] += 1;
        return;
    }

    swift_threading_defer_mutex_lock(&storage[CSHIMS_DEFER_RECURSIVE_LOCK]);
    storage[CSHIMS_DEFER_RECURSIVE_OWNER] = current;
    storage[CSHIMS_DEFER_RECURSIVE_COUNT] = 1;
}

void swift_threading_defer_recursive_mutex_unlock(uintptr_t *storage) {
    if (storage[CSHIMS_DEFER_RECURSIVE_COUNT] > 1) {
        storage[CSHIMS_DEFER_RECURSIVE_COUNT] -= 1;
        return;
    }

    storage[CSHIMS_DEFER_RECURSIVE_COUNT] = 0;
    storage[CSHIMS_DEFER_RECURSIVE_OWNER] = 0;
    swift_threading_defer_mutex_unlock(&storage[CSHIMS_DEFER_RECURSIVE_LOCK]);
}

void swift_threading_defer_cond_init(uintptr_t *handle) {
    swift_threading_defer_mutex_init(handle, false);
}

void swift_threading_defer_cond_destroy(uintptr_t *handle) {
    swift_threading_defer_mutex_destroy(handle);
}

void swift_threading_defer_cond_lock(uintptr_t *handle) {
    swift_threading_defer_mutex_lock(handle);
}

void swift_threading_defer_cond_unlock(uintptr_t *handle) {
    swift_threading_defer_mutex_unlock(handle);
}

void swift_threading_defer_cond_signal(uintptr_t *handle) {
    (void)handle;
}

void swift_threading_defer_cond_broadcast(uintptr_t *handle) {
    (void)handle;
}

void swift_threading_defer_cond_wait(uintptr_t *handle) {
    swift_threading_defer_cond_unlock(handle);
    cshims_core1_idle_pause();
    swift_threading_defer_cond_lock(handle);
}

bool swift_threading_defer_cond_wait_for(uintptr_t *handle, uint64_t ns) {
    (void)ns;
    swift_threading_defer_cond_wait(handle);
    return true;
}

bool swift_threading_defer_cond_wait_until(uintptr_t *handle, int64_t epochNs) {
    (void)epochNs;
    swift_threading_defer_cond_wait(handle);
    return true;
}

void swift_threading_defer_once(uintptr_t *predicate, void (*fn)(void *), void *ctx) {
    uintptr_t expected = 0;
    if (__atomic_compare_exchange_n(predicate, &expected, 1, false,
                                    __ATOMIC_ACQUIRE, __ATOMIC_RELAXED)) {
        fn(ctx);
        __atomic_store_n(predicate, 2, __ATOMIC_RELEASE);
        return;
    }

    while (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) != 2) {
        cshims_core1_idle_pause();
    }
}

void *swift_threading_defer_tls_get(uintptr_t key) {
    if (key >= CSHIMS_SWIFT_TLS_SLOT_COUNT) {
        return NULL;
    }

    return cshims_swift_tls_slots[cshims_core_index()][key];
}

void swift_threading_defer_tls_set(uintptr_t key, void *value) {
    if (key >= CSHIMS_SWIFT_TLS_SLOT_COUNT) {
        return;
    }

    cshims_swift_tls_slots[cshims_core_index()][key] = value;
}

static void cshims_threading_defer_probe_core1_entry(void) {
    void *low = NULL;
    void *high = NULL;

    cshims_threading_probe_core1_thread_id = swift_threading_defer_current_thread_id();
    cshims_threading_probe_core1_is_main = swift_threading_defer_is_main_thread() ? 1u : 0u;
    cshims_threading_probe_core1_slot0_before = (uintptr_t)swift_threading_defer_tls_get(0);
    cshims_threading_probe_core1_slot1_before = (uintptr_t)swift_threading_defer_tls_get(1);
    swift_threading_defer_tls_set(0, (void *)0xc1000100u);
    swift_threading_defer_tls_set(1, (void *)0xc1000101u);
    cshims_threading_probe_core1_slot0_after = (uintptr_t)swift_threading_defer_tls_get(0);
    cshims_threading_probe_core1_slot1_after = (uintptr_t)swift_threading_defer_tls_get(1);
    if (swift_threading_defer_current_stack_bounds(&low, &high)) {
        cshims_threading_probe_core1_stack_low = (uintptr_t)low;
        cshims_threading_probe_core1_stack_high = (uintptr_t)high;
    }

    cshims_threading_probe_done = 1;
    for (;;) {
        cshims_core1_idle_pause();
    }
}

static void cshims_threading_defer_probe_once_body(void *context) {
    uintptr_t *counter = (uintptr_t *)context;
    *counter += 1;
}

void cshims_threading_defer_probe_run(void) {
    void *low = NULL;
    void *high = NULL;
    uintptr_t mutex = 0;
    uintptr_t recursive[4] = {0, 0, 0, 0};
    uintptr_t oncePredicate = 0;
    uintptr_t onceCounter = 0;

    swift_threading_defer_tls_set(0, (void *)0xc0000100u);
    swift_threading_defer_tls_set(1, (void *)0xc0000101u);
    uintptr_t core0ThreadID = swift_threading_defer_current_thread_id();
    uint32_t core0IsMain = swift_threading_defer_is_main_thread() ? 1u : 0u;
    uintptr_t core0Slot0Before = (uintptr_t)swift_threading_defer_tls_get(0);
    uintptr_t core0Slot1Before = (uintptr_t)swift_threading_defer_tls_get(1);
    uint32_t core0HasStack = swift_threading_defer_current_stack_bounds(&low, &high) ? 1u : 0u;
    uintptr_t core0StackLow = (uintptr_t)low;
    uintptr_t core0StackHigh = (uintptr_t)high;

    swift_threading_defer_mutex_init(&mutex, true);
    bool mutexTry1 = swift_threading_defer_mutex_try_lock(&mutex);
    bool mutexTry2 = swift_threading_defer_mutex_try_lock(&mutex);
    swift_threading_defer_mutex_unlock(&mutex);
    bool mutexTry3 = swift_threading_defer_mutex_try_lock(&mutex);
    swift_threading_defer_mutex_unlock(&mutex);

    swift_threading_defer_recursive_mutex_init(recursive, true);
    swift_threading_defer_recursive_mutex_lock(recursive);
    swift_threading_defer_recursive_mutex_lock(recursive);
    swift_threading_defer_recursive_mutex_unlock(recursive);
    swift_threading_defer_recursive_mutex_unlock(recursive);

    swift_threading_defer_once(&oncePredicate, cshims_threading_defer_probe_once_body, &onceCounter);
    swift_threading_defer_once(&oncePredicate, cshims_threading_defer_probe_once_body, &onceCounter);

    cshims_threading_probe_done = 0;
    cshims_threading_probe_core1_thread_id = 0;
    cshims_threading_probe_core1_is_main = 0;
    cshims_threading_probe_core1_slot0_before = 0;
    cshims_threading_probe_core1_slot0_after = 0;
    cshims_threading_probe_core1_slot1_before = 0;
    cshims_threading_probe_core1_slot1_after = 0;
    cshims_threading_probe_core1_stack_low = 0;
    cshims_threading_probe_core1_stack_high = 0;

    multicore_reset_core1();
    multicore_launch_core1_with_stack(
        cshims_threading_defer_probe_core1_entry,
        cshims_tls_probe_core1_stack,
        sizeof(cshims_tls_probe_core1_stack));

    for (uint32_t i = 0; i < 100000u && !cshims_threading_probe_done; i++) {
        sleep_us(10);
    }

    uintptr_t core0Slot0After = (uintptr_t)swift_threading_defer_tls_get(0);
    uintptr_t core0Slot1After = (uintptr_t)swift_threading_defer_tls_get(1);
    uint32_t tlsLeak0 = core0Slot0After == 0xc1000100u ? 1u : 0u;
    uint32_t tlsLeak1 = core0Slot1After == 0xc1000101u ? 1u : 0u;

    printf("deferprobe done=%lu tid0=%lu main0=%lu stack0=%lx/%lx hs0=%lu s0b=%lx s0a=%lx s1b=%lx s1a=%lx tid1=%lu main1=%lu stack1=%lx/%lx s10b=%lx s10a=%lx s11b=%lx s11a=%lx leak0=%lu leak1=%lu m=%u%u%u once=%lu\n",
           (unsigned long)cshims_threading_probe_done,
           (unsigned long)core0ThreadID,
           (unsigned long)core0IsMain,
           (unsigned long)core0StackLow,
           (unsigned long)core0StackHigh,
           (unsigned long)core0HasStack,
           (unsigned long)core0Slot0Before,
           (unsigned long)core0Slot0After,
           (unsigned long)core0Slot1Before,
           (unsigned long)core0Slot1After,
           (unsigned long)cshims_threading_probe_core1_thread_id,
           (unsigned long)cshims_threading_probe_core1_is_main,
           (unsigned long)cshims_threading_probe_core1_stack_low,
           (unsigned long)cshims_threading_probe_core1_stack_high,
           (unsigned long)cshims_threading_probe_core1_slot0_before,
           (unsigned long)cshims_threading_probe_core1_slot0_after,
           (unsigned long)cshims_threading_probe_core1_slot1_before,
           (unsigned long)cshims_threading_probe_core1_slot1_after,
           (unsigned long)tlsLeak0,
           (unsigned long)tlsLeak1,
           mutexTry1 ? 1u : 0u,
           mutexTry2 ? 1u : 0u,
           mutexTry3 ? 1u : 0u,
           (unsigned long)onceCounter);

    multicore_reset_core1();
}

static void cshims_tls_probe_core1_entry(void) {
    cshims_tls_probe_core1_before = (uintptr_t)swift_task_getCurrent();
    cshims_swift_task_set_current((void *)0xc1000001u);
    cshims_tls_probe_core1_after = (uintptr_t)swift_task_getCurrent();
    cshims_tls_probe_done = 1;
    for (;;) {
        cshims_core1_idle_pause();
    }
}

void cshims_tls_probe_run(void) {
    cshims_tls_probe_done = 0;
    cshims_tls_probe_core1_before = 0;
    cshims_tls_probe_core1_after = 0;

    void *saved = swift_task_getCurrent();
    cshims_swift_task_set_current((void *)0xc0000000u);
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

    cshims_swift_task_set_current(saved);
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

void *cshims_job_owner_task(void *job) {
    void *asyncTask = cshims_job_async_task(job);
    if (asyncTask != NULL) {
        return asyncTask;
    }

    if (job == NULL) {
        return NULL;
    }

    enum {
        cshims_job_flags_offset = 16,
        cshims_job_size = 40,
        cshims_nullary_continuation_offset = cshims_job_size,
        cshims_job_kind_mask = 0xff,
        cshims_job_kind_nullary_continuation = 195
    };

    uint32_t flags;
    memcpy(&flags, (const char *)job + cshims_job_flags_offset, sizeof(flags));
    if ((flags & cshims_job_kind_mask) == cshims_job_kind_nullary_continuation) {
        void *continuation;
        memcpy(&continuation, (const char *)job + cshims_nullary_continuation_offset, sizeof(continuation));
        return continuation;
    }

    return NULL;
}

void *cshims_current_task(void) {
    return swift_task_getCurrent();
}

static void cshims_scheduler_core1_entry(void) {
    cshims_swift_task_clear_current();
    cshims_scheduler_core1_boot();
    cshims_scheduler_core1_seed();
    for (;;) {
        if (!cshims_scheduler_core1_loop_iteration()) {
            cshims_core1_idle_delay(256);
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
