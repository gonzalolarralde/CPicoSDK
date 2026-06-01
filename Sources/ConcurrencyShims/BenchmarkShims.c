#include "ConcurrencyShims.h"

#include <assert.h>
#include <stddef.h>
#include <stdint.h>

#ifndef CPICOSDK_CORE1_STACK_SIZE_BYTES
#define CPICOSDK_CORE1_STACK_SIZE_BYTES 8192u
#endif

extern uint64_t time_us_64(void);
extern void multicore_reset_core1(void);
extern void multicore_launch_core1_with_stack(void (*entry)(void), uint32_t *stack_bottom, size_t stack_size_bytes);
extern char __StackOneBottom;
extern char __StackOneTop;

typedef struct {
    volatile uint32_t gate;
    volatile uint32_t done;
    volatile uint32_t units;
    volatile uint32_t checksum;
    uint64_t deadline_us;
    uint32_t rounds;
} CShimsMulticoreSequentialBenchmark;

static CShimsMulticoreSequentialBenchmark cshims_multicore_sequential_benchmark = {0};

static unsigned int cshims_benchmark_core_num(void) {
    return *(volatile uint32_t *)0xd0000000u;
}

static void cshims_benchmark_signal_work(void) {
    __asm volatile("sev" ::: "memory");
}

static uint32_t cshims_benchmark_spin(uint32_t seed, uint32_t rounds) {
    uint32_t value = seed;
    for (uint32_t index = 0; index < rounds; index++) {
        value = value * 1664525u + 1013904223u + index;
        value ^= value >> 13;
    }
    return value;
}

static void cshims_benchmark_multicore_sequential_core1(void) {
    CShimsMulticoreSequentialBenchmark *state = &cshims_multicore_sequential_benchmark;
    while (__atomic_load_n(&state->gate, __ATOMIC_ACQUIRE) == 0u) {
        __asm volatile("wfe" ::: "memory");
    }

    uint32_t units = 0;
    uint32_t checksum = 2;
    uint64_t deadline = state->deadline_us;
    uint32_t rounds = state->rounds;
    while (time_us_64() < deadline) {
        checksum = cshims_benchmark_spin(checksum + units, rounds);
        units++;
    }

    state->units = units;
    state->checksum = checksum;
    __atomic_store_n(&state->done, 1u, __ATOMIC_RELEASE);
    for (;;) {
        __asm volatile("wfe" ::: "memory");
    }
}

void cshims_benchmark_multicore_sequential(
    uint64_t durationUs,
    uint32_t rounds,
    uint32_t *core0Units,
    uint32_t *core1Units,
    uint32_t *core0Checksum,
    uint32_t *core1Checksum,
    uint64_t *elapsedUs)
{
    assert((cshims_benchmark_core_num() & 1u) == 0u);
    assert(core0Units != 0);
    assert(core1Units != 0);
    assert(core0Checksum != 0);
    assert(core1Checksum != 0);
    assert(elapsedUs != 0);

    CShimsMulticoreSequentialBenchmark *state = &cshims_multicore_sequential_benchmark;
    state->gate = 0;
    state->done = 0;
    state->units = 0;
    state->checksum = 0;
    state->rounds = rounds;

    uint64_t started = time_us_64();
    state->deadline_us = started + durationUs;
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    multicore_reset_core1();
    multicore_launch_core1_with_stack(
        cshims_benchmark_multicore_sequential_core1,
        (uint32_t *)&__StackOneBottom,
        (size_t)(&__StackOneTop - &__StackOneBottom));

    __atomic_store_n(&state->gate, 1u, __ATOMIC_RELEASE);
    cshims_benchmark_signal_work();
#endif

    uint32_t units = 0;
    uint32_t checksum = 1;
    while (time_us_64() < state->deadline_us) {
        checksum = cshims_benchmark_spin(checksum + units, rounds);
        units++;
    }

#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    while (__atomic_load_n(&state->done, __ATOMIC_ACQUIRE) == 0u) {
        __asm volatile("nop");
    }
#endif

    *elapsedUs = time_us_64() - started;
    *core0Units = units;
#if CPICOSDK_CORE1_STACK_SIZE_BYTES > 0
    *core1Units = state->units;
    *core1Checksum = state->checksum;

    multicore_reset_core1();
#else
    *core1Units = 0;
    *core1Checksum = 0;
#endif
    *core0Checksum = checksum;
}
