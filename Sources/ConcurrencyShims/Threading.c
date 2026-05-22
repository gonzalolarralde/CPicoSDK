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

typedef void pico_mutex_t;
typedef void pico_recursive_mutex_t;
typedef void pico_semaphore_t;

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

static void swift_pico_trap(void) {
    for (;;) {
#if defined(__arm__) || defined(__thumb__)
        __asm__ volatile("bkpt #0");
#endif
    }
}

static void swift_pico_wait_hint(void) {
#if defined(__arm__) || defined(__thumb__)
    __asm__ volatile("wfe" ::: "memory");
#else
    __asm__ volatile("" ::: "memory");
#endif
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
#if defined(__arm__) || defined(__thumb__)
    return *SWIFT_PICO_SIO_CPUID & 1u;
#else
    return 0;
#endif
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
    if (low != NULL) {
        *low = NULL;
    }
    if (high != NULL) {
        *high = NULL;
    }
    return false;
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
        memset(storage, 0, sizeof(uintptr_t) * 4u);
    }
}

void swift_threading_defer_recursive_mutex_lock(uintptr_t *storage) {
    recursive_mutex_enter_blocking((pico_recursive_mutex_t *)storage);
}

void swift_threading_defer_recursive_mutex_unlock(uintptr_t *storage) {
    recursive_mutex_exit((pico_recursive_mutex_t *)storage);
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
#if defined(__arm__) || defined(__thumb__)
        __asm__ volatile("sev" ::: "memory");
#endif
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
