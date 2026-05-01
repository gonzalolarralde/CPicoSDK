#include "pico.h"
#include "CShims.h"

uint32_t __no_inline_not_in_flash_func(cshims_mmio_read32)(const volatile uint32_t *addr) {
    return *addr;
}

void __no_inline_not_in_flash_func(cshims_mmio_write32)(volatile uint32_t *addr, uint32_t value) {
    *addr = value;
}

void __no_inline_not_in_flash_func(cshims_mmio_set_bits32)(volatile uint32_t *addr, uint32_t mask) {
    *addr = *addr | mask;
}

void __no_inline_not_in_flash_func(cshims_mmio_clear_bits32)(volatile uint32_t *addr, uint32_t mask) {
    *addr = *addr & ~mask;
}

uint32_t __no_inline_not_in_flash_func(cshims_qmi_direct_rx_read32)(void) {
    return qmi_hw->direct_rx;
}
