#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Generic 32-bit volatile MMIO helpers.
uint32_t psram_mmio_read32_cshim(const volatile uint32_t *addr);
void psram_mmio_write32_cshim(volatile uint32_t *addr, uint32_t value);
void psram_mmio_set_bits32_cshim(volatile uint32_t *addr, uint32_t mask);
void psram_mmio_clear_bits32_cshim(volatile uint32_t *addr, uint32_t mask);

// Returns 1 on success, 0 on timeout/failure.
// kgd/eid are valid only when success is returned.
int psram_probe_id_cshim(unsigned int cs_pin, unsigned int *kgd, unsigned int *eid);

#ifdef __cplusplus
}
#endif
