#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Generic 32-bit volatile MMIO helpers.
uint32_t cshims_mmio_read32(const volatile uint32_t *addr);
void cshims_mmio_write32(volatile uint32_t *addr, uint32_t value);
void cshims_mmio_set_bits32(volatile uint32_t *addr, uint32_t mask);
void cshims_mmio_clear_bits32(volatile uint32_t *addr, uint32_t mask);
uint32_t cshims_qmi_direct_rx_read32(void);

void cshims_runtime_enable_required_coprocessors(void);

enum {
    CSHIMS_IRQ_ALLOCATOR_MALLOC = 1u,
    CSHIMS_IRQ_ALLOCATOR_CALLOC = 2u,
    CSHIMS_IRQ_ALLOCATOR_REALLOC = 3u,
    CSHIMS_IRQ_ALLOCATOR_FREE = 4u,
};

extern volatile uint32_t cshims_irq_allocator_operation;
extern volatile uint32_t cshims_irq_allocator_exception;
extern volatile uint32_t cshims_irq_allocator_core;

void cshims_record_irq_allocator_use(uint32_t operation, uint32_t exception);
void cshims_warn_irq_allocator_use(uint32_t operation, uint32_t exception);
void cshims_irq_allocator_debug_break(void);

#ifdef __cplusplus
}
#endif
