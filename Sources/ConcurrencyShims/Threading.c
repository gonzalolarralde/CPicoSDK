#include "ConcurrencyShims.h"

#include <limits.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#define SWIFT_PICO_SYNC_WORDS 16u
#define SWIFT_PICO_TLS_KEYS 16u
#define SWIFT_PICO_MAX_CORES 2u
#define SWIFT_PICO_COND_MAX_WAITERS INT16_MAX
#define SWIFT_PICO_SIO_CPUID ((volatile uint32_t *)0xd0000000u)

#ifndef CPICOSDK_CORE1_STACK_SIZE_BYTES
#define CPICOSDK_CORE1_STACK_SIZE_BYTES 8192u
#endif

#if defined(__GNUC__) || defined(__clang__)
#define SWIFT_PICO_WEAK __attribute__((weak))
#define SWIFT_PICO_PAL_ENTRY __attribute__((section(".text.swift_embedded_platform")))
#else
#define SWIFT_PICO_WEAK
#define SWIFT_PICO_PAL_ENTRY
#endif

typedef void pico_mutex_t;
typedef void pico_recursive_mutex_t;
typedef void pico_semaphore_t;

typedef struct {
    void *spin_lock;
    int8_t owner;
    uint8_t enter_count;
} SwiftPicoRecursiveMutexStorage;

extern void mutex_init(pico_mutex_t *mtx);
extern void mutex_enter_blocking(pico_mutex_t *mtx);
extern bool mutex_try_enter(pico_mutex_t *mtx, uint32_t *owner_out);
extern void mutex_exit(pico_mutex_t *mtx);

extern void recursive_mutex_init(pico_recursive_mutex_t *mtx);
extern void recursive_mutex_enter_blocking(pico_recursive_mutex_t *mtx);
extern void recursive_mutex_exit(pico_recursive_mutex_t *mtx);

extern void sem_init(pico_semaphore_t *sem, int16_t initial_permits, int16_t max_permits);
extern void sem_acquire_blocking(pico_semaphore_t *sem);
extern bool sem_acquire_timeout_us(pico_semaphore_t *sem, uint32_t timeout_us);
extern bool sem_try_acquire(pico_semaphore_t *sem);
extern bool sem_release(pico_semaphore_t *sem);

extern uint64_t time_us_64(void);

extern char __StackBottom SWIFT_PICO_WEAK;
extern char __StackTop SWIFT_PICO_WEAK;
extern char __StackOneBottom SWIFT_PICO_WEAK;
extern char __StackOneTop SWIFT_PICO_WEAK;

typedef struct {
    uintptr_t words[SWIFT_PICO_SYNC_WORDS];
} SwiftPicoSyncStorage;

typedef struct {
    SwiftPicoSyncStorage storage;
} SwiftPicoMutex;

typedef struct {
    SwiftPicoSyncStorage lock;
    SwiftPicoSyncStorage semaphore;
    uint32_t waiters;
} SwiftPicoCondition;

static void *swift_pico_tls[SWIFT_PICO_MAX_CORES][SWIFT_PICO_TLS_KEYS];
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
extern uint32_t cshims_scheduler_core1_stack[CPICOSDK_CORE1_STACK_SIZE_BYTES / sizeof(uint32_t)];
#endif

void *cshims_scheduler_core1_stack_bottom(void) {
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    return cshims_scheduler_core1_stack;
#else
    return NULL;
#endif
}

uint32_t cshims_scheduler_core1_stack_size_bytes(void) {
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    return CPICOSDK_CORE1_STACK_SIZE_BYTES;
#else
    return 0;
#endif
}

static char *swift_pico_scheduler_core1_stack_bottom(void) {
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    return (char *)cshims_scheduler_core1_stack;
#else
    return NULL;
#endif
}

static char *swift_pico_scheduler_core1_stack_top(void) {
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    return (char *)cshims_scheduler_core1_stack + CPICOSDK_CORE1_STACK_SIZE_BYTES;
#else
    return NULL;
#endif
}

static void swift_pico_trap(void) {
    for (;;) {
        __asm__ volatile("bkpt #0");
    }
}

static void swift_pico_wait_hint(void) {
    __asm__ volatile("wfe" ::: "memory");
}

static SwiftPicoMutex *swift_pico_alloc_mutex(void) {
    SwiftPicoMutex *mutex = (SwiftPicoMutex *)calloc(1, sizeof(SwiftPicoMutex));
    if (mutex == NULL) {
        swift_pico_trap();
    }
    mutex_init((pico_mutex_t *)&mutex->storage);
    return mutex;
}

static SwiftPicoMutex *swift_pico_get_or_init_mutex(uintptr_t *handle) {
    uintptr_t current = __atomic_load_n(handle, __ATOMIC_ACQUIRE);
    if (current != 0) {
        return (SwiftPicoMutex *)current;
    }

    SwiftPicoMutex *created = swift_pico_alloc_mutex();
    uintptr_t createdValue = (uintptr_t)created;
    uintptr_t expected = 0;
    if (__atomic_compare_exchange_n(
            handle,
            &expected,
            createdValue,
            false,
            __ATOMIC_RELEASE,
            __ATOMIC_ACQUIRE)) {
        return created;
    }

    free(created);
    return (SwiftPicoMutex *)expected;
}

static SwiftPicoCondition *swift_pico_get_condition(uintptr_t *handle) {
    return (SwiftPicoCondition *)__atomic_load_n(handle, __ATOMIC_ACQUIRE);
}

static uint32_t swift_pico_core_index(void) {
    return *SWIFT_PICO_SIO_CPUID & 1u;
}

static uintptr_t swift_pico_stack_pointer(void) {
    uintptr_t sp;
    __asm__ volatile("mov %0, sp" : "=r"(sp));
    return sp;
}

static bool swift_pico_stack_bounds_from_symbols(
    char *bottom,
    char *top,
    void **low,
    void **high
) {
    if (bottom == NULL || top == NULL || bottom >= top) {
        return false;
    }

    *low = bottom;
    *high = top;
    return true;
}

static bool swift_pico_stack_bounds_if_contains_sp(
    char *bottom,
    char *top,
    uintptr_t sp,
    void **low,
    void **high
) {
    if (bottom == NULL || top == NULL || bottom >= top) {
        return false;
    }

    if (sp >= (uintptr_t)bottom && sp <= (uintptr_t)top) {
        *low = bottom;
        *high = top;
        return true;
    }

    return false;
}

static uint32_t swift_pico_timeout_us_from_ns(uint64_t ns) {
    uint64_t us = ns / 1000u;
    if ((ns % 1000u) != 0) {
        us += 1u;
    }
    if (us > UINT32_MAX) {
        return UINT32_MAX;
    }
    return (uint32_t)us;
}

static bool swift_pico_condition_wait_us(SwiftPicoCondition *condition, uint32_t timeoutUs, bool timed) {
    if (condition->waiters < UINT32_MAX) {
        condition->waiters += 1u;
    }

    mutex_exit((pico_mutex_t *)&condition->lock);

    bool acquired = true;
    if (timed) {
        acquired = sem_acquire_timeout_us((pico_semaphore_t *)&condition->semaphore, timeoutUs);
    } else {
        sem_acquire_blocking((pico_semaphore_t *)&condition->semaphore);
    }

    mutex_enter_blocking((pico_mutex_t *)&condition->lock);

    if (!acquired) {
        if (sem_try_acquire((pico_semaphore_t *)&condition->semaphore)) {
            acquired = true;
        } else if (condition->waiters > 0) {
            condition->waiters -= 1u;
        }
    }

    return acquired;
}

uintptr_t swift_threading_defer_current_thread_id(void) {
    return (uintptr_t)(swift_pico_core_index() + 1u);
}

bool swift_threading_defer_is_main_thread(void) {
    return swift_pico_core_index() == 0;
}

bool swift_threading_defer_current_stack_bounds(void **low, void **high) {
    if (low == NULL || high == NULL) {
        return false;
    }

    *low = NULL;
    *high = NULL;

    uintptr_t sp = swift_pico_stack_pointer();
    if (swift_pico_stack_bounds_if_contains_sp(&__StackBottom, &__StackTop, sp, low, high)) {
        return true;
    }
    if (swift_pico_stack_bounds_if_contains_sp(&__StackOneBottom, &__StackOneTop, sp, low, high)) {
        return true;
    }
    if (swift_pico_stack_bounds_if_contains_sp(
            swift_pico_scheduler_core1_stack_bottom(),
            swift_pico_scheduler_core1_stack_top(),
            sp,
            low,
            high)) {
        return true;
    }

    if (swift_pico_core_index() == 0u) {
        return swift_pico_stack_bounds_from_symbols(&__StackBottom, &__StackTop, low, high);
    }
    if (swift_pico_stack_bounds_from_symbols(
            swift_pico_scheduler_core1_stack_bottom(),
            swift_pico_scheduler_core1_stack_top(),
            low,
            high)) {
        return true;
    }
    return swift_pico_stack_bounds_from_symbols(&__StackOneBottom, &__StackOneTop, low, high);
}

void swift_threading_defer_mutex_init(uintptr_t *handle, bool checked) {
    (void)checked;
    if (handle == NULL) {
        return;
    }
    SwiftPicoMutex *mutex = swift_pico_alloc_mutex();
    __atomic_store_n(handle, (uintptr_t)mutex, __ATOMIC_RELEASE);
}

void swift_threading_defer_mutex_destroy(uintptr_t *handle) {
    if (handle == NULL) {
        return;
    }
    SwiftPicoMutex *mutex = (SwiftPicoMutex *)__atomic_exchange_n(handle, 0, __ATOMIC_ACQ_REL);
    free(mutex);
}

void swift_threading_defer_mutex_lock(uintptr_t *handle) {
    SwiftPicoMutex *mutex = swift_pico_get_or_init_mutex(handle);
    mutex_enter_blocking((pico_mutex_t *)&mutex->storage);
}

void swift_threading_defer_mutex_unlock(uintptr_t *handle) {
    SwiftPicoMutex *mutex = (SwiftPicoMutex *)__atomic_load_n(handle, __ATOMIC_ACQUIRE);
    if (mutex != NULL) {
        mutex_exit((pico_mutex_t *)&mutex->storage);
    }
}

bool swift_threading_defer_mutex_try_lock(uintptr_t *handle) {
    SwiftPicoMutex *mutex = swift_pico_get_or_init_mutex(handle);
    return mutex_try_enter((pico_mutex_t *)&mutex->storage, NULL);
}

void swift_threading_defer_recursive_mutex_init(uintptr_t *storage, bool checked) {
    (void)checked;
    if (storage == NULL) {
        return;
    }
    recursive_mutex_init((pico_recursive_mutex_t *)storage);
}

void swift_threading_defer_recursive_mutex_destroy(uintptr_t *storage) {
    if (storage != NULL) {
        memset(storage, 0, sizeof(pico_recursive_mutex_t));
    }
}

static pico_recursive_mutex_t *swift_pico_get_or_init_recursive_mutex(uintptr_t *storage) {
    if (storage == NULL) {
        return NULL;
    }

    pico_recursive_mutex_t *mutex = (pico_recursive_mutex_t *)storage;
    SwiftPicoRecursiveMutexStorage *typedStorage = (SwiftPicoRecursiveMutexStorage *)storage;
    if (typedStorage->spin_lock == NULL) {
        recursive_mutex_init(mutex);
    }
    return mutex;
}

void swift_threading_defer_recursive_mutex_lock(uintptr_t *storage) {
    pico_recursive_mutex_t *mutex = swift_pico_get_or_init_recursive_mutex(storage);
    if (mutex != NULL) {
        recursive_mutex_enter_blocking(mutex);
    }
}

void swift_threading_defer_recursive_mutex_unlock(uintptr_t *storage) {
    pico_recursive_mutex_t *mutex = (pico_recursive_mutex_t *)storage;
    SwiftPicoRecursiveMutexStorage *typedStorage = (SwiftPicoRecursiveMutexStorage *)storage;
    if (mutex != NULL && typedStorage->spin_lock != NULL) {
        recursive_mutex_exit(mutex);
    }
}

void swift_threading_defer_cond_init(uintptr_t *handle) {
    if (handle == NULL) {
        return;
    }

    SwiftPicoCondition *condition = (SwiftPicoCondition *)calloc(1, sizeof(SwiftPicoCondition));
    if (condition == NULL) {
        swift_pico_trap();
    }

    mutex_init((pico_mutex_t *)&condition->lock);
    sem_init((pico_semaphore_t *)&condition->semaphore, 0, SWIFT_PICO_COND_MAX_WAITERS);
    __atomic_store_n(handle, (uintptr_t)condition, __ATOMIC_RELEASE);
}

void swift_threading_defer_cond_destroy(uintptr_t *handle) {
    if (handle == NULL) {
        return;
    }
    SwiftPicoCondition *condition = (SwiftPicoCondition *)__atomic_exchange_n(handle, 0, __ATOMIC_ACQ_REL);
    free(condition);
}

void swift_threading_defer_cond_lock(uintptr_t *handle) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition != NULL) {
        mutex_enter_blocking((pico_mutex_t *)&condition->lock);
    }
}

void swift_threading_defer_cond_unlock(uintptr_t *handle) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition != NULL) {
        mutex_exit((pico_mutex_t *)&condition->lock);
    }
}

void swift_threading_defer_cond_signal(uintptr_t *handle) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition != NULL && condition->waiters > 0) {
        condition->waiters -= 1u;
        (void)sem_release((pico_semaphore_t *)&condition->semaphore);
    }
}

void swift_threading_defer_cond_broadcast(uintptr_t *handle) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition == NULL) {
        return;
    }

    uint32_t waiters = condition->waiters;
    condition->waiters = 0;
    while (waiters > 0) {
        (void)sem_release((pico_semaphore_t *)&condition->semaphore);
        waiters -= 1u;
    }
}

void swift_threading_defer_cond_wait(uintptr_t *handle) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition != NULL) {
        (void)swift_pico_condition_wait_us(condition, 0, false);
    }
}

bool swift_threading_defer_cond_wait_for(uintptr_t *handle, uint64_t ns) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition == NULL) {
        return false;
    }
    return swift_pico_condition_wait_us(condition, swift_pico_timeout_us_from_ns(ns), true);
}

bool swift_threading_defer_cond_wait_until(uintptr_t *handle, int64_t epochNs) {
    SwiftPicoCondition *condition = swift_pico_get_condition(handle);
    if (condition == NULL) {
        return false;
    }

    int64_t nowNs = (int64_t)(time_us_64() * 1000u);
    if (epochNs <= nowNs) {
        return swift_pico_condition_wait_us(condition, 0, true);
    }

    return swift_pico_condition_wait_us(
        condition,
        swift_pico_timeout_us_from_ns((uint64_t)(epochNs - nowNs)),
        true);
}

void swift_threading_defer_once(uintptr_t *predicate, void (*fn)(void *), void *ctx) {
    const uintptr_t running = 1u;
    const uintptr_t done = UINTPTR_MAX;

    uintptr_t state = __atomic_load_n(predicate, __ATOMIC_ACQUIRE);
    if (state == done) {
        return;
    }

    uintptr_t expected = 0;
    if (__atomic_compare_exchange_n(
            predicate,
            &expected,
            running,
            false,
            __ATOMIC_ACQ_REL,
        __ATOMIC_ACQUIRE)) {
        fn(ctx);
        __atomic_store_n(predicate, done, __ATOMIC_RELEASE);
        __asm__ volatile("sev" ::: "memory");
        return;
    }

    while (__atomic_load_n(predicate, __ATOMIC_ACQUIRE) != done) {
        swift_pico_wait_hint();
    }
}

void *swift_threading_defer_tls_get(uintptr_t key) {
    if (key >= SWIFT_PICO_TLS_KEYS) {
        return NULL;
    }
    return swift_pico_tls[swift_pico_core_index()][key];
}

void swift_threading_defer_tls_set(uintptr_t key, void *value) {
    if (key >= SWIFT_PICO_TLS_KEYS) {
        return;
    }
    swift_pico_tls[swift_pico_core_index()][key] = value;
}

// Swift's EmbeddedPlatform abstraction replaced the deferred threading hooks
// with caller-owned mutex storage and reserved TLS keys. Keep one Pico
// implementation and expose both ABIs while released and preview toolchains
// overlap. The first mutex word remains an owning pointer to the Pico object;
// EmbeddedPlatform guarantees at least eight pointer-sized words of storage.
SWIFT_PICO_PAL_ENTRY
void _swift_mutex_init(void *storage, unsigned long long flags) {
    swift_threading_defer_mutex_init((uintptr_t *)storage, (flags & 1u) != 0u);
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutex_destroy(void *storage) {
    swift_threading_defer_mutex_destroy((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutex_lock(void *storage) {
    swift_threading_defer_mutex_lock((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutex_unlock(void *storage) {
    swift_threading_defer_mutex_unlock((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
ptrdiff_t _swift_mutex_tryLock(void *storage) {
    return swift_threading_defer_mutex_try_lock((uintptr_t *)storage) ? 1 : 0;
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutexRecursive_init(void *storage, unsigned long long flags) {
    swift_threading_defer_recursive_mutex_init(
        (uintptr_t *)storage,
        (flags & 1u) != 0u
    );
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutexRecursive_destroy(void *storage) {
    swift_threading_defer_recursive_mutex_destroy((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutexRecursive_lock(void *storage) {
    swift_threading_defer_recursive_mutex_lock((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
void _swift_mutexRecursive_unlock(void *storage) {
    swift_threading_defer_recursive_mutex_unlock((uintptr_t *)storage);
}

SWIFT_PICO_PAL_ENTRY
void _swift_tls_init(ptrdiff_t key, void (*destructor)(void *)) {
    // Both Pico cores are fixed execution contexts that never exit, so the
    // EmbeddedPlatform contract does not require destructor invocation.
    (void)key;
    (void)destructor;
}

SWIFT_PICO_PAL_ENTRY
void *_swift_tls_get(ptrdiff_t key) {
    if (key < 0) {
        return NULL;
    }
    return swift_threading_defer_tls_get((uintptr_t)key);
}

SWIFT_PICO_PAL_ENTRY
void _swift_tls_set(ptrdiff_t key, void *value) {
    if (key < 0) {
        return;
    }
    swift_threading_defer_tls_set((uintptr_t)key, value);
}

SWIFT_PICO_PAL_ENTRY
ptrdiff_t _swift_thread_isMain(void) {
    return swift_threading_defer_is_main_thread() ? 1 : 0;
}
