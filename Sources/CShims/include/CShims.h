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

#ifdef __cplusplus
}
#endif
