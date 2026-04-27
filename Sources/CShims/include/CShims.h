#pragma once
#include <stdint.h>

// PICO_CONFIG: PICO_USE_MALLOC_MUTEX, Whether to protect malloc etc with a mutex, type=bool, default=1 with pico_multicore, 0 otherwise, group=pico_malloc
#if LIB_PICO_MULTICORE && !defined(PICO_USE_MALLOC_MUTEX)
#define PICO_USE_MALLOC_MUTEX 1
#endif

// PICO_CONFIG: PICO_MALLOC_PANIC, Enable/disable panic when an allocation failure occurs, type=bool, default=1, group=pico_malloc
#ifndef PICO_MALLOC_PANIC
#define PICO_MALLOC_PANIC 1
#endif

// PICO_CONFIG: PICO_DEBUG_MALLOC, Enable/disable debug printf from malloc, type=bool, default=0, group=pico_malloc
#ifndef PICO_DEBUG_MALLOC
#define PICO_DEBUG_MALLOC 0
#endif

// PICO_CONFIG: PICO_DEBUG_MALLOC_LOW_WATER, Define the lower bound for allocation addresses to be printed by PICO_DEBUG_MALLOC, min=0, default=0, group=pico_malloc
#ifndef PICO_DEBUG_MALLOC_LOW_WATER
#define PICO_DEBUG_MALLOC_LOW_WATER 0
#endif


#ifdef __cplusplus
extern "C" {
#endif

// Generic 32-bit volatile MMIO helpers.
uint32_t cshims_mmio_read32(const volatile uint32_t *addr);
void cshims_mmio_write32(volatile uint32_t *addr, uint32_t value);
void cshims_mmio_set_bits32(volatile uint32_t *addr, uint32_t mask);
void cshims_mmio_clear_bits32(volatile uint32_t *addr, uint32_t mask);
uint32_t cshims_qmi_direct_rx_read32(void);

#ifdef __cplusplus
}
#endif
