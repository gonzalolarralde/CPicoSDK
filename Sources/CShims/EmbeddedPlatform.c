#include "../ConcurrencyShims/include/ConcurrencyShims.h"

#include <stddef.h>
#include <string.h>

#define SWIFT_PICO_MAX_CORES 2u
#define SWIFT_PICO_SIO_CPUID ((volatile uint32_t *)0xd0000000u)

typedef void pico_mutex_t;
typedef void pico_recursive_mutex_t;

typedef struct {
    void *spin_lock;
    int8_t owner;
} SwiftPicoMutexStorage;

typedef struct {
    void *spin_lock;
    int8_t owner;
    uint8_t enter_count;
} SwiftPicoRecursiveMutexStorage;

_Static_assert(
    sizeof(SwiftPicoMutexStorage) <=
        (size_t)EMBEDDED_SWIFT_MUTEX_NUM_WORDS * sizeof(void *),
    "Pico mutex storage exceeds EmbeddedPlatform.h's mutex storage contract");

_Static_assert(
    sizeof(SwiftPicoRecursiveMutexStorage) <=
        (size_t)EMBEDDED_SWIFT_MUTEX_RECURSIVE_NUM_WORDS * sizeof(void *),
    "Pico recursive mutex storage exceeds EmbeddedPlatform.h's recursive mutex storage contract");

extern void mutex_init(pico_mutex_t *mtx);
extern void mutex_enter_blocking(pico_mutex_t *mtx);
extern void mutex_exit(pico_mutex_t *mtx);

extern void recursive_mutex_init(pico_recursive_mutex_t *mtx);
extern void recursive_mutex_enter_blocking(pico_recursive_mutex_t *mtx);
extern void recursive_mutex_exit(pico_recursive_mutex_t *mtx);

static void *swift_pico_tls[SWIFT_PICO_MAX_CORES][SWIFT_TLS_KEY_COUNT];

static uint32_t swift_pico_core_index(void) {
    return *SWIFT_PICO_SIO_CPUID & 1u;
}

void _swift_mutex_init(void *storage, swift_mutex_flags_t flags) {
    (void)flags;
    memset(
        storage,
        0,
        (size_t)EMBEDDED_SWIFT_MUTEX_NUM_WORDS * sizeof(void *));
    mutex_init((pico_mutex_t *)storage);
}

void _swift_mutex_destroy(void *storage) {
    memset(
        storage,
        0,
        (size_t)EMBEDDED_SWIFT_MUTEX_NUM_WORDS * sizeof(void *));
}

void _swift_mutex_lock(void *storage) {
    mutex_enter_blocking((pico_mutex_t *)storage);
}

void _swift_mutex_unlock(void *storage) {
    mutex_exit((pico_mutex_t *)storage);
}

void _swift_mutexRecursive_init(void *storage, swift_mutex_flags_t flags) {
    (void)flags;
    memset(
        storage,
        0,
        (size_t)EMBEDDED_SWIFT_MUTEX_RECURSIVE_NUM_WORDS * sizeof(void *));
    recursive_mutex_init((pico_recursive_mutex_t *)storage);
}

void _swift_mutexRecursive_destroy(void *storage) {
    memset(
        storage,
        0,
        (size_t)EMBEDDED_SWIFT_MUTEX_RECURSIVE_NUM_WORDS * sizeof(void *));
}

void _swift_mutexRecursive_lock(void *storage) {
    recursive_mutex_enter_blocking((pico_recursive_mutex_t *)storage);
}

void _swift_mutexRecursive_unlock(void *storage) {
    recursive_mutex_exit((pico_recursive_mutex_t *)storage);
}

void *_swift_tls_get(swift_tls_key_t key) {
    if (key < 0 || key >= SWIFT_TLS_KEY_COUNT) {
        return NULL;
    }
    return swift_pico_tls[swift_pico_core_index()][key];
}

void _swift_tls_set(swift_tls_key_t key, void *value) {
    if (key < 0 || key >= SWIFT_TLS_KEY_COUNT) {
        return;
    }
    swift_pico_tls[swift_pico_core_index()][key] = value;
}

__swift_ptrdiff_t _swift_thread_isMain(void) {
    return swift_pico_core_index() == 0u;
}
