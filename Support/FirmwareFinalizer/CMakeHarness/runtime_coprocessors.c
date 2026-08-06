#include "pico.h"

#if defined(PICO_RP2350) && !defined(__riscv)
#include "hardware/gpio.h"
#include "hardware/structs/m33.h"

#ifndef M33_CPACR_CP10_BITS
#define M33_CPACR_CP10_BITS 0x00300000u
#endif

#ifndef M33_CPACR_CP11_BITS
#define M33_CPACR_CP11_BITS 0x00c00000u
#endif

void runtime_init_per_core_enable_coprocessors(void) {
    uint32_t bits = M33_CPACR_CP10_BITS | M33_CPACR_CP11_BITS;
#if HAS_DOUBLE_COPROCESSOR
    bits |= M33_CPACR_CP4_BITS;
#endif
#if PICO_USE_GPIO_COPROCESSOR
    bits |= M33_CPACR_CP0_BITS;
#endif

    arm_cpu_hw->cpacr |= bits;
    __asm__ volatile("dsb\nisb" ::: "memory");

#if HAS_DOUBLE_COPROCESSOR
    __asm__ volatile("mrc p4,#0,r0,c0,c0,#1" ::: "r0");
#endif
}
#endif
