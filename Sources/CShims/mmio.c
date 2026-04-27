#if __has_include("CPicoSDK_pimoroni_pico_plus2_w_rp2350.h")
#include "CPicoSDK_pimoroni_pico_plus2_w_rp2350.h"
#elif __has_include("CPicoSDK_pimoroni_pico_plus2_rp2350.h")
#include "CPicoSDK_pimoroni_pico_plus2_rp2350.h"
#elif __has_include("CPicoSDK_pico2_w.h")
#include "CPicoSDK_pico2_w.h"
#elif __has_include("CPicoSDK_pico2.h")
#include "CPicoSDK_pico2.h"
#else
#error "No CPicoSDK board header available for PSRAMAllocatorShim"
#endif

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
