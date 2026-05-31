#include "ConcurrencyShims.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <errno.h>
#include <assert.h>
#include <string.h>
#include <time.h>

#if defined(__clang__)
#define SWIFT_CC_SWIFT __attribute__((swiftcall))
#define SWIFT_NORETURN __attribute__((noreturn))
#else
#define SWIFT_CC_SWIFT
#define SWIFT_NORETURN
#endif

#define CSHIMS_SCHEDULER_RAM __attribute__((section(".time_critical.cshims_scheduler")))
#define CSHIMS_SCHEDULER_LATE_FLASH __attribute__((section(".cpicosdk_late_text.cshims_scheduler")))

typedef struct {
    void *first;
    void *second;
} SwiftExecutorRef;

extern void SWIFT_CC_SWIFT swift_job_run(void *job, void *executorFirst, void *executorSecond);
extern uint8_t SWIFT_CC_SWIFT swift_job_getPriority(void *job) __attribute__((weak));
extern bool SWIFT_CC_SWIFT swift_task_isCurrentExecutor(SwiftExecutorRef executor);
extern void *SWIFT_CC_SWIFT cshims_swift_task_clear_current_runtime(void) __asm__("_ZN5swift24_swift_task_clearCurrentEv");
extern const void *cshims_swift_task_heap_metadata_ptr __asm__("_ZN5swift19taskHeapMetadataPtrE");

struct _reent;

static volatile uint32_t cshims_malloc_lock_word = 0;
static volatile uint32_t cshims_malloc_lock_owner = 0;
static volatile uint32_t cshims_malloc_lock_depth[2] = {0, 0};
static volatile uint32_t cshims_malloc_lock_irq_state[2] = {0, 0};

static unsigned int CSHIMS_SCHEDULER_RAM cshims_core_num(void) {
    return *(volatile uint32_t *)0xd0000000u;
}

static uint32_t cshims_malloc_save_and_disable_interrupts(void) {
#if defined(__arm__) || defined(__thumb__)
    uint32_t state;
    __asm volatile("mrs %0, primask\ncpsid i" : "=r"(state) :: "memory");
    return state;
#else
    return 0;
#endif
}

static void cshims_malloc_restore_interrupts(uint32_t state) {
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

    uint32_t irq_state = cshims_malloc_save_and_disable_interrupts();
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
    cshims_malloc_restore_interrupts(irq_state);
}

extern int cshims_scheduler_poll_once(void);
extern void cshims_scheduler_wait_for_work_forever(void);

extern uint64_t time_us_64(void);
typedef void alarm_pool_t;
typedef uint64_t absolute_time_t;
typedef int32_t alarm_id_t;
extern alarm_pool_t *alarm_pool_get_default(void);
extern alarm_id_t alarm_pool_add_alarm_at(
    alarm_pool_t *pool,
    absolute_time_t time,
    int64_t (*callback)(int32_t id, void *user_data),
    void *user_data,
    bool fire_if_past);
extern void multicore_reset_core1(void);
extern void multicore_launch_core1_with_stack(void (*entry)(void), uint32_t *stack_bottom, size_t stack_size_bytes);
extern void cshims_scheduler_run_deferred_item(void *item);
extern void cshims_scheduler_record_task_start(uint32_t core) __attribute__((weak));
extern void cshims_scheduler_record_task_end(uint32_t core) __attribute__((weak));
extern void cshims_scheduler_record_idle_sample(uint32_t core) __attribute__((weak));
extern void cshims_scheduler_collect_cpu_reports(void) __attribute__((weak));
enum {
    CSHIMS_SCHEDULER_MAX_JOBS = 256,
    CSHIMS_SCHEDULER_MAX_OWNERS = 128,
    CSHIMS_SCHEDULER_PRIORITY_BUCKETS = 5,
    CSHIMS_SCHEDULER_MAX_DEFERRED = 128,
    CSHIMS_SCHEDULER_NONE = 0xffffu,
    CSHIMS_SIO_SPINLOCK31 = 0xd000017cu
};

typedef struct {
    void *job;
    void *executor_first;
    void *executor_second;
    void *owner;
    uint16_t next;
    int16_t owner_slot;
    uint8_t priority;
} CShimsSchedulerJob;

typedef struct {
    void *owner;
    uint16_t wait_head;
    uint16_t wait_tail;
    bool running;
    bool ready;
    uint8_t state;
} CShimsSchedulerOwner;

static CShimsSchedulerJob cshims_scheduler_jobs[CSHIMS_SCHEDULER_MAX_JOBS];
static CShimsSchedulerOwner cshims_scheduler_owners[CSHIMS_SCHEDULER_MAX_OWNERS];
static uint16_t cshims_scheduler_free_head = CSHIMS_SCHEDULER_NONE;
static uint16_t cshims_scheduler_ready_head[CSHIMS_SCHEDULER_PRIORITY_BUCKETS];
static uint16_t cshims_scheduler_ready_tail[CSHIMS_SCHEDULER_PRIORITY_BUCKETS];
static uint8_t cshims_scheduler_priority_cursor = 0;
static void *cshims_scheduler_deferred[CSHIMS_SCHEDULER_MAX_DEFERRED];
static uint16_t cshims_scheduler_deferred_head = 0;
static uint16_t cshims_scheduler_deferred_tail = 0;
static uint16_t cshims_scheduler_deferred_count = 0;
static bool cshims_scheduler_initialized = false;
static bool cshims_scheduler_multicore_enabled = false;

static uint32_t CSHIMS_SCHEDULER_RAM cshims_scheduler_lock(void);
static void CSHIMS_SCHEDULER_RAM cshims_scheduler_unlock(uint32_t irq_state);
static void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_init_locked(void);

static uint32_t CSHIMS_SCHEDULER_RAM cshims_scheduler_irq_disable(void) {
    uint32_t state;
    __asm volatile(
        "mrs %0, primask\n"
        "cpsid i\n"
        : "=r"(state)
        :
        : "memory");
    return state;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_irq_restore(uint32_t state) {
    __asm volatile("msr primask, %0\n" : : "r"(state) : "memory");
}

void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_prepare_lock(void) {
    *(volatile uint32_t *)CSHIMS_SIO_SPINLOCK31 = 0u;
    // Initialize eagerly so scheduler runtime hooks do not carry the cold setup path.
    uint32_t irq_state = cshims_scheduler_lock();
    cshims_scheduler_init_locked();
    cshims_scheduler_unlock(irq_state);
}

static uint32_t CSHIMS_SCHEDULER_RAM cshims_scheduler_lock(void) {
    uint32_t irq_state = cshims_scheduler_irq_disable();
    volatile uint32_t *spinlock = (volatile uint32_t *)CSHIMS_SIO_SPINLOCK31;
    while (*spinlock == 0u) {
        __asm volatile("nop");
    }
    __asm volatile("" ::: "memory");
    return irq_state;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_unlock(uint32_t irq_state) {
    __asm volatile("" ::: "memory");
    *(volatile uint32_t *)CSHIMS_SIO_SPINLOCK31 = 0u;
    cshims_scheduler_irq_restore(irq_state);
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_signal_work(void) {
    __asm volatile("sev" ::: "memory");
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_wait_event(void) {
    __asm volatile("wfe" ::: "memory");
}

static uint8_t CSHIMS_SCHEDULER_RAM cshims_scheduler_priority_bucket(uint8_t raw) {
    if (raw >= 25u) {
        return 0u;
    }
    if (raw >= 21u) {
        return 1u;
    }
    if (raw >= 17u) {
        return 2u;
    }
    if (raw >= 9u) {
        return 3u;
    }
    return 4u;
}

static uintptr_t CSHIMS_SCHEDULER_RAM cshims_scheduler_owner_hash(void *owner) {
    uintptr_t value = (uintptr_t)owner;
    value >>= 3;
    value ^= value >> 11;
    value *= 2654435761u;
    return value;
}

static void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_init_locked(void) {
    if (cshims_scheduler_initialized) {
        return;
    }

    for (uint16_t i = 0; i < CSHIMS_SCHEDULER_MAX_JOBS; i++) {
        cshims_scheduler_jobs[i].next = (uint16_t)(i + 1u);
    }
    cshims_scheduler_jobs[CSHIMS_SCHEDULER_MAX_JOBS - 1u].next = CSHIMS_SCHEDULER_NONE;
    cshims_scheduler_free_head = 0;

    for (uint16_t i = 0; i < CSHIMS_SCHEDULER_PRIORITY_BUCKETS; i++) {
        cshims_scheduler_ready_head[i] = CSHIMS_SCHEDULER_NONE;
        cshims_scheduler_ready_tail[i] = CSHIMS_SCHEDULER_NONE;
    }

    for (uint16_t i = 0; i < CSHIMS_SCHEDULER_MAX_OWNERS; i++) {
        cshims_scheduler_owners[i].owner = NULL;
        cshims_scheduler_owners[i].wait_head = CSHIMS_SCHEDULER_NONE;
        cshims_scheduler_owners[i].wait_tail = CSHIMS_SCHEDULER_NONE;
        cshims_scheduler_owners[i].running = false;
        cshims_scheduler_owners[i].ready = false;
        cshims_scheduler_owners[i].state = 0u;
    }

    cshims_scheduler_initialized = true;
}

static uint16_t CSHIMS_SCHEDULER_RAM cshims_scheduler_alloc_job_locked(void) {
    assert(cshims_scheduler_free_head != CSHIMS_SCHEDULER_NONE);
    uint16_t index = cshims_scheduler_free_head;
    cshims_scheduler_free_head = cshims_scheduler_jobs[index].next;
    cshims_scheduler_jobs[index].next = CSHIMS_SCHEDULER_NONE;
    return index;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_free_job_locked(uint16_t index) {
    cshims_scheduler_jobs[index].next = cshims_scheduler_free_head;
    cshims_scheduler_free_head = index;
}

static int16_t CSHIMS_SCHEDULER_RAM cshims_scheduler_find_owner_locked(void *owner, bool create) {
    if (owner == NULL) {
        return -1;
    }

    uintptr_t start = cshims_scheduler_owner_hash(owner) % CSHIMS_SCHEDULER_MAX_OWNERS;
    int16_t first_tombstone = -1;

    for (uintptr_t probe = 0; probe < CSHIMS_SCHEDULER_MAX_OWNERS; probe++) {
        uintptr_t index = (start + probe) % CSHIMS_SCHEDULER_MAX_OWNERS;
        CShimsSchedulerOwner *entry = &cshims_scheduler_owners[index];
        if (entry->state == 1u && entry->owner == owner) {
            return (int16_t)index;
        }
        if (entry->state == 2u && first_tombstone < 0) {
            first_tombstone = (int16_t)index;
        }
        if (entry->state == 0u) {
            if (!create) {
                return -1;
            }
            int16_t selected = first_tombstone >= 0 ? first_tombstone : (int16_t)index;
            CShimsSchedulerOwner *created = &cshims_scheduler_owners[selected];
            created->owner = owner;
            created->wait_head = CSHIMS_SCHEDULER_NONE;
            created->wait_tail = CSHIMS_SCHEDULER_NONE;
            created->running = false;
            created->ready = false;
            created->state = 1u;
            return selected;
        }
    }

    assert(first_tombstone >= 0);
    if (create && first_tombstone >= 0) {
        CShimsSchedulerOwner *created = &cshims_scheduler_owners[first_tombstone];
        created->owner = owner;
        created->wait_head = CSHIMS_SCHEDULER_NONE;
        created->wait_tail = CSHIMS_SCHEDULER_NONE;
        created->running = false;
        created->ready = false;
        created->state = 1u;
        return first_tombstone;
    }
    return -1;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_release_owner_if_idle_locked(int16_t owner_slot) {
    if (owner_slot < 0) {
        return;
    }

    CShimsSchedulerOwner *owner = &cshims_scheduler_owners[owner_slot];
    if (!owner->running && !owner->ready && owner->wait_head == CSHIMS_SCHEDULER_NONE) {
        owner->owner = NULL;
        owner->state = 2u;
    }
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_push_ready_locked(uint16_t job_index) {
    CShimsSchedulerJob *job = &cshims_scheduler_jobs[job_index];
    uint8_t priority = job->priority;
    assert(priority < CSHIMS_SCHEDULER_PRIORITY_BUCKETS);
    job->next = CSHIMS_SCHEDULER_NONE;
    if (cshims_scheduler_ready_tail[priority] != CSHIMS_SCHEDULER_NONE) {
        cshims_scheduler_jobs[cshims_scheduler_ready_tail[priority]].next = job_index;
    } else {
        cshims_scheduler_ready_head[priority] = job_index;
    }
    cshims_scheduler_ready_tail[priority] = job_index;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_make_runnable_locked(uint16_t job_index) {
    CShimsSchedulerJob *job = &cshims_scheduler_jobs[job_index];
    int16_t owner_slot = cshims_scheduler_find_owner_locked(job->owner, true);
    job->owner_slot = owner_slot;

    if (owner_slot < 0) {
        cshims_scheduler_push_ready_locked(job_index);
        return;
    }

    CShimsSchedulerOwner *owner = &cshims_scheduler_owners[owner_slot];
    if (owner->running || owner->ready || owner->wait_head != CSHIMS_SCHEDULER_NONE) {
        job->next = CSHIMS_SCHEDULER_NONE;
        if (owner->wait_tail != CSHIMS_SCHEDULER_NONE) {
            cshims_scheduler_jobs[owner->wait_tail].next = job_index;
        } else {
            owner->wait_head = job_index;
        }
        owner->wait_tail = job_index;
        return;
    }

    owner->ready = true;
    cshims_scheduler_push_ready_locked(job_index);
}

static uint16_t CSHIMS_SCHEDULER_RAM cshims_scheduler_pop_from_priority_locked(uint8_t priority) {
    uint16_t current = cshims_scheduler_ready_head[priority];
    if (current == CSHIMS_SCHEDULER_NONE) {
        return CSHIMS_SCHEDULER_NONE;
    }

    CShimsSchedulerJob *job = &cshims_scheduler_jobs[current];
    cshims_scheduler_ready_head[priority] = job->next;
    if (cshims_scheduler_ready_tail[priority] == current) {
        cshims_scheduler_ready_tail[priority] = CSHIMS_SCHEDULER_NONE;
    }
    job->next = CSHIMS_SCHEDULER_NONE;

    if (job->owner_slot >= 0) {
        CShimsSchedulerOwner *owner = &cshims_scheduler_owners[job->owner_slot];
        owner->ready = false;
        owner->running = true;
    }

    return current;
}

static uint16_t CSHIMS_SCHEDULER_RAM cshims_scheduler_pop_ready_locked(void) {
    static const uint8_t priority_order[] = {
        0, 0, 0, 0,
        1,
        0, 0,
        1,
        2,
        0, 0,
        1,
        3,
        0,
        2,
        4,
    };
    const uint8_t order_count = (uint8_t)(sizeof(priority_order) / sizeof(priority_order[0]));

    for (uint8_t attempt = 0; attempt < order_count; attempt++) {
        uint8_t order_index = (uint8_t)((cshims_scheduler_priority_cursor + attempt) % order_count);
        uint8_t priority = priority_order[order_index];
        uint16_t index = cshims_scheduler_pop_from_priority_locked(priority);
        if (index == CSHIMS_SCHEDULER_NONE) {
            continue;
        }

        cshims_scheduler_priority_cursor = (uint8_t)((order_index + 1u) % order_count);
        return index;
    }

    return CSHIMS_SCHEDULER_NONE;
}

static bool CSHIMS_SCHEDULER_RAM cshims_scheduler_has_ready_locked(void) {
    if (cshims_scheduler_deferred_count > 0) {
        return true;
    }
    for (uint8_t priority = 0; priority < CSHIMS_SCHEDULER_PRIORITY_BUCKETS; priority++) {
        if (cshims_scheduler_ready_head[priority] != CSHIMS_SCHEDULER_NONE) {
            return true;
        }
    }
    return false;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_finish_job(uint16_t job_index, int16_t owner_slot) {
    uint32_t irq_state = cshims_scheduler_lock();

    if (owner_slot >= 0) {
        CShimsSchedulerOwner *owner = &cshims_scheduler_owners[owner_slot];
        owner->running = false;
        uint16_t next = owner->wait_head;
        if (next != CSHIMS_SCHEDULER_NONE) {
            owner->wait_head = cshims_scheduler_jobs[next].next;
            if (owner->wait_head == CSHIMS_SCHEDULER_NONE) {
                owner->wait_tail = CSHIMS_SCHEDULER_NONE;
            }
            cshims_scheduler_jobs[next].next = CSHIMS_SCHEDULER_NONE;
            owner->ready = true;
            cshims_scheduler_push_ready_locked(next);
        } else {
            cshims_scheduler_release_owner_if_idle_locked(owner_slot);
        }
    }

    cshims_scheduler_free_job_locked(job_index);
    cshims_scheduler_unlock(irq_state);
    cshims_scheduler_signal_work();
}

static int64_t CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_alarm_callback(int32_t id, void *user_data) {
    (void)id;
    uint16_t job_index = (uint16_t)(((uintptr_t)user_data) - 1u);

    uint32_t irq_state = cshims_scheduler_lock();
    cshims_scheduler_make_runnable_locked(job_index);
    cshims_scheduler_unlock(irq_state);
    cshims_scheduler_signal_work();

    return 0;
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_enqueue_job(
    void *job,
    void *executorFirst,
    void *executorSecond,
    uint64_t delayUs,
    bool delayed)
{
    void *owner = cshims_job_owner_task(job);
    uint8_t priority = cshims_scheduler_priority_bucket(cshims_job_priority(job));

    uint32_t irq_state = cshims_scheduler_lock();
    uint16_t job_index = cshims_scheduler_alloc_job_locked();
    cshims_scheduler_jobs[job_index].job = job;
    cshims_scheduler_jobs[job_index].executor_first = executorFirst;
    cshims_scheduler_jobs[job_index].executor_second = executorSecond;
    cshims_scheduler_jobs[job_index].owner = owner;
    cshims_scheduler_jobs[job_index].owner_slot = -1;
    cshims_scheduler_jobs[job_index].priority = priority;
    cshims_scheduler_jobs[job_index].next = CSHIMS_SCHEDULER_NONE;

    if (!delayed || delayUs == 0u) {
        cshims_scheduler_make_runnable_locked(job_index);
    }
    cshims_scheduler_unlock(irq_state);

    if (delayed && delayUs > 0u) {
        int32_t alarm = alarm_pool_add_alarm_at(
            alarm_pool_get_default(),
            time_us_64() + delayUs,
            cshims_scheduler_alarm_callback,
            (void *)((uintptr_t)job_index + 1u),
            true);
        assert(alarm > 0);
    }

    cshims_scheduler_signal_work();
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_enqueue_immediate(void *job, void *executorFirst, void *executorSecond) {
    cshims_scheduler_enqueue_job(job, executorFirst, executorSecond, 0u, false);
}

static void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_enqueue_delayed(
    uint64_t delayUs,
    void *job,
    void *executorFirst,
    void *executorSecond)
{
    cshims_scheduler_enqueue_job(job, executorFirst, executorSecond, delayUs, true);
}

static void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_enqueue_deadline(
    uint64_t deadlineUs,
    void *job,
    void *executorFirst,
    void *executorSecond)
{
    uint64_t now = time_us_64();
    uint64_t delayUs = deadlineUs > now ? deadlineUs - now : 0u;
    cshims_scheduler_enqueue_job(job, executorFirst, executorSecond, delayUs, true);
}

void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_enqueue_deferred(void *item) {
    uint32_t irq_state = cshims_scheduler_lock();
    assert(cshims_scheduler_deferred_count < CSHIMS_SCHEDULER_MAX_DEFERRED);
    cshims_scheduler_deferred[cshims_scheduler_deferred_tail] = item;
    cshims_scheduler_deferred_tail = (uint16_t)((cshims_scheduler_deferred_tail + 1u) % CSHIMS_SCHEDULER_MAX_DEFERRED);
    cshims_scheduler_deferred_count++;
    cshims_scheduler_unlock(irq_state);
    cshims_scheduler_signal_work();
}

int CSHIMS_SCHEDULER_RAM cshims_scheduler_poll_once(void) {
    void *deferred_item = NULL;
    uint16_t job_index = CSHIMS_SCHEDULER_NONE;
    CShimsSchedulerJob job_snapshot;

    uint32_t irq_state = cshims_scheduler_lock();

    if (cshims_scheduler_deferred_count > 0) {
        deferred_item = cshims_scheduler_deferred[cshims_scheduler_deferred_head];
        cshims_scheduler_deferred_head = (uint16_t)((cshims_scheduler_deferred_head + 1u) % CSHIMS_SCHEDULER_MAX_DEFERRED);
        cshims_scheduler_deferred_count--;
    } else {
        job_index = cshims_scheduler_pop_ready_locked();
        if (job_index != CSHIMS_SCHEDULER_NONE) {
            job_snapshot = cshims_scheduler_jobs[job_index];
        }
    }

    cshims_scheduler_unlock(irq_state);

    if (deferred_item != NULL) {
        cshims_scheduler_run_deferred_item(deferred_item);
        return 1;
    }

    if (job_index == CSHIMS_SCHEDULER_NONE) {
        uint32_t core = cshims_core_num() & 1u;
        if (cshims_scheduler_record_idle_sample != NULL) {
            cshims_scheduler_record_idle_sample(core);
        }
        if (cshims_scheduler_collect_cpu_reports != NULL && core == 0u) {
            cshims_scheduler_collect_cpu_reports();
        }
        return 0;
    }

    uint32_t core = cshims_core_num() & 1u;
    if (cshims_scheduler_record_task_start != NULL) {
        cshims_scheduler_record_task_start(core);
    }
    cshims_run_job_bridge(job_snapshot.job, job_snapshot.executor_first, job_snapshot.executor_second);
    if (cshims_scheduler_record_task_end != NULL) {
        cshims_scheduler_record_task_end(core);
    }
    if (cshims_scheduler_collect_cpu_reports != NULL && core == 0u) {
        cshims_scheduler_collect_cpu_reports();
    }

    cshims_scheduler_finish_job(job_index, job_snapshot.owner_slot);
    return 1;
}

void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_wait_for_work_forever(void) {
    for (;;) {
        uint32_t irq_state = cshims_scheduler_lock();
        bool has_ready = cshims_scheduler_has_ready_locked();
        cshims_scheduler_unlock(irq_state);
        if (has_ready) {
            return;
        }
        uint32_t core = cshims_core_num() & 1u;
        if (cshims_scheduler_record_idle_sample != NULL) {
            cshims_scheduler_record_idle_sample(core);
        }
        if (cshims_scheduler_collect_cpu_reports != NULL && core == 0u) {
            cshims_scheduler_collect_cpu_reports();
        }
        cshims_scheduler_wait_event();
    }
}

static void CSHIMS_SCHEDULER_RAM cshims_scheduler_core1_entry_c(void) {
    cshims_swift_task_clear_current();
    for (;;) {
        if (!cshims_scheduler_poll_once()) {
            cshims_scheduler_wait_for_work_forever();
        }
    }
}

void CSHIMS_SCHEDULER_LATE_FLASH cshims_scheduler_start_multicore(void) {
    if ((cshims_core_num() & 1u) != 0u) {
        return;
    }

    uint32_t irq_state = cshims_scheduler_lock();
    bool should_start = !cshims_scheduler_multicore_enabled;
    cshims_scheduler_multicore_enabled = true;
    cshims_scheduler_unlock(irq_state);

    if (!should_start) {
        return;
    }

    multicore_reset_core1();
    multicore_launch_core1_with_stack(
        cshims_scheduler_core1_entry_c,
        (uint32_t *)cshims_scheduler_core1_stack_bottom(),
        cshims_scheduler_core1_stack_size_bytes());
    cshims_scheduler_signal_work();
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

void CSHIMS_SCHEDULER_RAM cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond) {
    swift_job_run(job, executorFirst, executorSecond);
}

void CSHIMS_SCHEDULER_RAM cshims_swift_task_clear_current(void) {
    cshims_swift_task_clear_current_runtime();
}

void *CSHIMS_SCHEDULER_RAM cshims_job_owner_task(void *job) {
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

    void *metadata;
    memcpy(&metadata, job, sizeof(metadata));

    if (metadata == cshims_swift_task_heap_metadata_ptr) {
        return job;
    }

    uint32_t flags;
    memcpy(&flags, (const char *)job + cshims_job_flags_offset, sizeof(flags));
    if ((flags & cshims_job_kind_mask) == cshims_job_kind_nullary_continuation) {
        void *continuation;
        memcpy(&continuation, (const char *)job + cshims_nullary_continuation_offset, sizeof(continuation));
        return continuation;
    }

    return NULL;
}

uint8_t CSHIMS_SCHEDULER_RAM cshims_job_priority(void *job) {
    if (job != NULL && swift_job_getPriority != NULL) {
        return swift_job_getPriority(job);
    }
    return 0;
}

uint32_t cshims_enter_critical(void) {
    uint32_t status;
    __asm volatile(
        "mrs %0, primask\n"
        "cpsid i\n"
        : "=r"(status)
        :
        : "memory");
    return status;
}

void cshims_exit_critical(uint32_t state) {
    __asm volatile("msr primask, %0\n" : : "r"(state) : "memory");
}

SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_RAM swift_task_enqueueGlobalImpl(void *job) {
    cshims_scheduler_enqueue_immediate(job, NULL, NULL);
}

SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_RAM swift_task_enqueueMainExecutorImpl(void *job) {
    cshims_scheduler_enqueue_immediate(job, NULL, NULL);
}

SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_LATE_FLASH swift_task_enqueueGlobalWithDelayImpl(uint64_t delay, void *job) {
    uint64_t delayUs = delay / 1000u;
    if (delay > 0 && delayUs == 0) {
        delayUs = 1;
    }
    cshims_scheduler_enqueue_delayed(delayUs, job, NULL, NULL);
}

SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_LATE_FLASH swift_task_enqueueGlobalWithDeadlineImpl(
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

SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_LATE_FLASH swift_task_donateThreadToGlobalExecutorUntilImpl(
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

SWIFT_NORETURN SWIFT_CC_SWIFT void CSHIMS_SCHEDULER_RAM swift_task_asyncMainDrainQueueImpl(void) {
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
