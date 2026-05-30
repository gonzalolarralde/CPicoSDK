#include "pico.h"
#include "CShims.h"

#if defined(PICO_RP2350) && !defined(__riscv)

#ifndef M33_CPACR_CP10_BITS
#define M33_CPACR_CP10_BITS 0x00300000u
#endif

#ifndef M33_CPACR_CP11_BITS
#define M33_CPACR_CP11_BITS 0x00c00000u
#endif

void cshims_runtime_enable_required_coprocessors(void) {
    volatile uint32_t *cpacr = (volatile uint32_t *)0xe000ed88u;
    uint32_t bits = M33_CPACR_CP10_BITS | M33_CPACR_CP11_BITS;

#if HAS_DOUBLE_COPROCESSOR
    bits |= M33_CPACR_CP4_BITS;
#endif
#if PICO_USE_GPIO_COPROCESSOR
    bits |= M33_CPACR_CP0_BITS;
#endif

    *cpacr |= bits;
    __asm__ volatile("dsb\nisb" ::: "memory");

#if HAS_DOUBLE_COPROCESSOR
    __asm__ volatile("mrc p4,#0,r0,c0,c0,#1" ::: "r0");
#endif
}

void runtime_init_per_core_enable_coprocessors(void) {
    cshims_runtime_enable_required_coprocessors();
}

#else

void cshims_runtime_enable_required_coprocessors(void) {
}

#endif
