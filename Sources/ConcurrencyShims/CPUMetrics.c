#include "ConcurrencyShims.h"

#if defined(CPUMetrics)

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

#if __has_include("hardware/clocks.h")
#include "hardware/clocks.h"
#endif

extern uint64_t time_us_64(void);

enum {
    CSHIMS_CPU_METRICS_CORE_COUNT = 2,
    CSHIMS_CPU_METRICS_WINDOW_US = 1000000u,
    CSHIMS_DWT_CTRL_CYCCNTENA = 1u << 0,
    CSHIMS_DWT_CTRL_LSUEVTENA = 1u << 20,
    CSHIMS_DWT_CTRL_NOPRFCNT = 1u << 24,
    CSHIMS_DWT_CTRL_NOCYCCNT = 1u << 25,
    CSHIMS_DEMCR_TRCENA = 1u << 24,
    CSHIMS_CLK_SYS = 5u,
};

typedef struct {
    atomic_flag busy;
    bool initialized;
    bool task_active;
    uint32_t interrupt_depth;

    uint64_t window_start_us;
    uint64_t last_us;
    uint32_t last_cycles;
    uint8_t last_lsu;

    uint64_t task_us;
    uint64_t interrupt_us;
    uint64_t idle_us;
    uint64_t interrupt_events;

    uint64_t task_cycles;
    uint64_t interrupt_cycles;
    uint64_t idle_cycles;

    uint64_t task_lsu;
    uint64_t interrupt_lsu;
    uint64_t idle_lsu;
} CShimsCPUMetricsCore;

static CShimsCPUMetricsCore cshims_cpu_metrics_cores[CSHIMS_CPU_METRICS_CORE_COUNT] = {
    { .busy = ATOMIC_FLAG_INIT },
    { .busy = ATOMIC_FLAG_INIT },
};

static atomic_uint_fast32_t cshims_cpu_metrics_pending_interrupt_events[CSHIMS_CPU_METRICS_CORE_COUNT];
static atomic_uint_fast32_t cshims_cpu_metrics_pending_interrupt_time_us[CSHIMS_CPU_METRICS_CORE_COUNT];
static atomic_bool cshims_cpu_metrics_enabled = false;
static atomic_bool cshims_cpu_metrics_hw_initialized = false;
static bool cshims_cpu_metrics_has_cycles = false;
static bool cshims_cpu_metrics_has_lsu = false;
static uint32_t cshims_cpu_metrics_cycles_per_second = 0;

#if defined(__arm__) || defined(__thumb__)
static volatile uint32_t *const cshims_demcr = (volatile uint32_t *)0xe000edfcu;
static volatile uint32_t *const cshims_dwt_ctrl = (volatile uint32_t *)0xe0001000u;
static volatile uint32_t *const cshims_dwt_cyccnt = (volatile uint32_t *)0xe0001004u;
static volatile uint32_t *const cshims_dwt_lsucnt = (volatile uint32_t *)0xe0001014u;

static uint32_t cshims_cpu_metrics_read_cycles(void) {
    return *cshims_dwt_cyccnt;
}

static uint8_t cshims_cpu_metrics_read_lsu(void) {
    return (uint8_t)(*cshims_dwt_lsucnt);
}
#else
static uint32_t cshims_cpu_metrics_read_cycles(void) {
    return 0;
}

static uint8_t cshims_cpu_metrics_read_lsu(void) {
    return 0;
}
#endif

static void cshims_cpu_metrics_init_hw(void) {
    if (atomic_load_explicit(&cshims_cpu_metrics_hw_initialized, memory_order_acquire)) {
        return;
    }

#if defined(__arm__) || defined(__thumb__)
    *cshims_demcr |= CSHIMS_DEMCR_TRCENA;

    uint32_t ctrl = *cshims_dwt_ctrl;
    bool cycles_supported = (ctrl & CSHIMS_DWT_CTRL_NOCYCCNT) == 0u;
    bool lsu_supported = (ctrl & CSHIMS_DWT_CTRL_NOPRFCNT) == 0u;

    if (cycles_supported) {
        *cshims_dwt_cyccnt = 0u;
        *cshims_dwt_ctrl = ctrl | CSHIMS_DWT_CTRL_CYCCNTENA;
        uint32_t start = *cshims_dwt_cyccnt;
        for (volatile uint32_t i = 0; i < 64u; i++) {
            __asm volatile("nop");
        }
        cshims_cpu_metrics_has_cycles = (*cshims_dwt_cyccnt != start);
    }

    if (lsu_supported) {
        *cshims_dwt_lsucnt = 0u;
        *cshims_dwt_ctrl = *cshims_dwt_ctrl | CSHIMS_DWT_CTRL_LSUEVTENA;
        cshims_cpu_metrics_has_lsu = true;
    }
#endif

#if __has_include("hardware/clocks.h")
    cshims_cpu_metrics_cycles_per_second = clock_get_hz((clock_handle_t)CSHIMS_CLK_SYS);
#else
    cshims_cpu_metrics_cycles_per_second = 0;
#endif

    if (cshims_cpu_metrics_cycles_per_second == 0u) {
        cshims_cpu_metrics_has_cycles = false;
    }

    atomic_store_explicit(&cshims_cpu_metrics_hw_initialized, true, memory_order_release);
}

static uint64_t cshims_cpu_metrics_cycles_to_us(uint32_t cycles) {
    if (!cshims_cpu_metrics_has_cycles || cshims_cpu_metrics_cycles_per_second == 0u) {
        return 0;
    }
    return ((uint64_t)cycles * 1000000ull) / (uint64_t)cshims_cpu_metrics_cycles_per_second;
}

static bool cshims_cpu_metrics_try_enter(CShimsCPUMetricsCore *state) {
    return !atomic_flag_test_and_set_explicit(&state->busy, memory_order_acquire);
}

static void cshims_cpu_metrics_exit(CShimsCPUMetricsCore *state) {
    atomic_flag_clear_explicit(&state->busy, memory_order_release);
}

static void cshims_cpu_metrics_add_to_current_bucket(
    CShimsCPUMetricsCore *state,
    uint64_t elapsed_us,
    uint32_t elapsed_cycles,
    uint8_t elapsed_lsu)
{
    if (state->interrupt_depth > 0u) {
        state->interrupt_us += elapsed_us;
        state->interrupt_cycles += elapsed_cycles;
        state->interrupt_lsu += elapsed_lsu;
    } else if (state->task_active) {
        state->task_us += elapsed_us;
        state->task_cycles += elapsed_cycles;
        state->task_lsu += elapsed_lsu;
    } else {
        state->idle_us += elapsed_us;
        state->idle_cycles += elapsed_cycles;
        state->idle_lsu += elapsed_lsu;
    }
}

static void cshims_cpu_metrics_account(CShimsCPUMetricsCore *state, uint32_t core) {
    cshims_cpu_metrics_init_hw();

    uint64_t now_us = time_us_64();
    uint32_t now_cycles = cshims_cpu_metrics_read_cycles();
    uint8_t now_lsu = cshims_cpu_metrics_read_lsu();

    uint32_t pending_events = atomic_exchange_explicit(
        &cshims_cpu_metrics_pending_interrupt_events[core],
        0u,
        memory_order_acq_rel);
    uint32_t pending_time_us = atomic_exchange_explicit(
        &cshims_cpu_metrics_pending_interrupt_time_us[core],
        0u,
        memory_order_acq_rel);

    if (!state->initialized) {
        state->initialized = true;
        state->window_start_us = now_us;
        state->last_us = now_us;
        state->last_cycles = now_cycles;
        state->last_lsu = now_lsu;
        state->interrupt_events += pending_events;
        state->interrupt_us += pending_time_us;
        return;
    }

    uint64_t elapsed_us = now_us - state->last_us;
    uint32_t elapsed_cycles = now_cycles - state->last_cycles;
    uint8_t elapsed_lsu = (uint8_t)(now_lsu - state->last_lsu);
    state->last_us = now_us;
    state->last_cycles = now_cycles;
    state->last_lsu = now_lsu;

    state->interrupt_events += pending_events;

    uint64_t sampled_interrupt_us = pending_time_us < elapsed_us ? pending_time_us : elapsed_us;
    state->interrupt_us += sampled_interrupt_us;
    elapsed_us -= sampled_interrupt_us;

    cshims_cpu_metrics_add_to_current_bucket(state, elapsed_us, elapsed_cycles, elapsed_lsu);
}

static void cshims_cpu_metrics_record_locked(uint32_t core, uint32_t event) {
    if (!atomic_load_explicit(&cshims_cpu_metrics_enabled, memory_order_relaxed)) {
        return;
    }

    if (core >= CSHIMS_CPU_METRICS_CORE_COUNT) {
        return;
    }

    CShimsCPUMetricsCore *state = &cshims_cpu_metrics_cores[core];
    if (!cshims_cpu_metrics_try_enter(state)) {
        if (event == 2u) {
            atomic_fetch_add_explicit(&cshims_cpu_metrics_pending_interrupt_events[core], 1u, memory_order_relaxed);
        }
        return;
    }

    cshims_cpu_metrics_account(state, core);

    switch (event) {
    case 0u:
        state->task_active = true;
        break;
    case 1u:
        state->task_active = false;
        break;
    case 2u:
        state->interrupt_depth++;
        state->interrupt_events++;
        break;
    case 3u:
        if (state->interrupt_depth > 0u) {
            state->interrupt_depth--;
        }
        break;
    default:
        break;
    }

    cshims_cpu_metrics_exit(state);
}

void cshims_cpu_metrics_record_task_start(uint32_t core) {
    cshims_cpu_metrics_record_locked(core, 0u);
}

void cshims_cpu_metrics_record_task_end(uint32_t core) {
    cshims_cpu_metrics_record_locked(core, 1u);
}

void cshims_cpu_metrics_record_idle_sample(uint32_t core) {
    cshims_cpu_metrics_record_locked(core, 4u);
}

void cshims_cpu_metrics_record_interrupt_enter(uint32_t core) {
    cshims_cpu_metrics_record_locked(core, 2u);
}

void cshims_cpu_metrics_record_interrupt_exit(uint32_t core) {
    cshims_cpu_metrics_record_locked(core, 3u);
}

bool cshims_cpu_metrics_take_report(uint32_t core, cshims_cpu_metrics_report_t *report) {
    if (!atomic_load_explicit(&cshims_cpu_metrics_enabled, memory_order_relaxed)) {
        return false;
    }

    if (core >= CSHIMS_CPU_METRICS_CORE_COUNT || report == NULL) {
        return false;
    }

    CShimsCPUMetricsCore *state = &cshims_cpu_metrics_cores[core];
    if (!cshims_cpu_metrics_try_enter(state)) {
        return false;
    }

    cshims_cpu_metrics_account(state, core);

    uint64_t elapsed_window_us = state->last_us - state->window_start_us;
    if (!state->initialized || elapsed_window_us < CSHIMS_CPU_METRICS_WINDOW_US) {
        cshims_cpu_metrics_exit(state);
        return false;
    }

    memset(report, 0, sizeof(*report));
    report->timestampUs = state->last_us;
    report->core = core;
    report->taskUs = state->task_us;
    report->interruptUs = state->interrupt_us;
    report->idleUs = state->idle_us;
    report->totalUs = state->task_us + state->interrupt_us + state->idle_us;
    report->interruptEvents = state->interrupt_events;

    if (cshims_cpu_metrics_has_cycles) {
        report->flags |= CSHIMS_CPU_METRICS_REPORT_HAS_CYCLES;
        report->taskCycles = state->task_cycles;
        report->interruptCycles = state->interrupt_cycles;
        report->idleCycles = state->idle_cycles;
        report->totalCycles = state->task_cycles + state->interrupt_cycles + state->idle_cycles;
    }

    if (cshims_cpu_metrics_has_lsu) {
        report->flags |= CSHIMS_CPU_METRICS_REPORT_HAS_LOAD_STORE_STALLS;
        report->taskLoadStoreStallCount = state->task_lsu;
        report->interruptLoadStoreStallCount = state->interrupt_lsu;
        report->idleLoadStoreStallCount = state->idle_lsu;
        report->loadStoreStallCount = state->task_lsu + state->interrupt_lsu + state->idle_lsu;
    }

    state->window_start_us = state->last_us;
    state->task_us = 0u;
    state->interrupt_us = 0u;
    state->idle_us = 0u;
    state->interrupt_events = 0u;
    state->task_cycles = 0u;
    state->interrupt_cycles = 0u;
    state->idle_cycles = 0u;
    state->task_lsu = 0u;
    state->interrupt_lsu = 0u;
    state->idle_lsu = 0u;

    cshims_cpu_metrics_exit(state);
    return true;
}

void cshims_cpu_metrics_record_interrupt_sample(uint32_t core, uint64_t events, uint64_t timeUs) {
    if (!atomic_load_explicit(&cshims_cpu_metrics_enabled, memory_order_relaxed)) {
        return;
    }

    if (core >= CSHIMS_CPU_METRICS_CORE_COUNT) {
        return;
    }
    uint32_t event_count = events > UINT32_MAX ? UINT32_MAX : (uint32_t)events;
    uint32_t time_count = timeUs > UINT32_MAX ? UINT32_MAX : (uint32_t)timeUs;
    atomic_fetch_add_explicit(&cshims_cpu_metrics_pending_interrupt_events[core], event_count, memory_order_relaxed);
    atomic_fetch_add_explicit(&cshims_cpu_metrics_pending_interrupt_time_us[core], time_count, memory_order_relaxed);
}

void cshims_cpu_metrics_take_interrupt_samples(uint32_t core, uint64_t *events, uint64_t *timeUs) {
    if (events == NULL || timeUs == NULL) {
        return;
    }
    if (core >= CSHIMS_CPU_METRICS_CORE_COUNT) {
        *events = 0u;
        *timeUs = 0u;
        return;
    }
    *events = atomic_exchange_explicit(
        &cshims_cpu_metrics_pending_interrupt_events[core],
        0u,
        memory_order_acq_rel);
    *timeUs = atomic_exchange_explicit(
        &cshims_cpu_metrics_pending_interrupt_time_us[core],
        0u,
        memory_order_acq_rel);
}

void cshims_cpu_metrics_set_enabled(bool enabled) {
    atomic_store_explicit(&cshims_cpu_metrics_enabled, enabled, memory_order_release);
    if (enabled) {
        cshims_cpu_metrics_init_hw();
    }
}

#endif
