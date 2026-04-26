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

#include "PSRAMAllocatorShim.h"

#define PSRAM_CMD_QUAD_END   0xF5u
#define PSRAM_CMD_READ_ID    0x9Fu
#define PSRAM_CMD_NOOP       0xFFu

#define SHIM_POLL_TIMEOUT 10000000u

static int wait_busy_clear(void) {
    uint32_t timeout = SHIM_POLL_TIMEOUT;
    while ((qmi_hw->direct_csr & QMI_DIRECT_CSR_BUSY_BITS) != 0) {
        if (--timeout == 0) return 0;
    }
    return 1;
}

static int wait_tx_not_full(void) {
    uint32_t timeout = SHIM_POLL_TIMEOUT;
    while ((qmi_hw->direct_csr & QMI_DIRECT_CSR_TXFULL_BITS) != 0) {
        if (--timeout == 0) return 0;
    }
    return 1;
}

static int wait_rx_not_empty(void) {
    uint32_t timeout = SHIM_POLL_TIMEOUT;
    while ((qmi_hw->direct_csr & QMI_DIRECT_CSR_RXEMPTY_BITS) != 0) {
        if (--timeout == 0) return 0;
    }
    return 1;
}

int __no_inline_not_in_flash_func(psram_probe_id_cshim)(unsigned int cs_pin, unsigned int *kgd, unsigned int *eid) {
    if (!kgd || !eid) return 0;

    *kgd = 0;
    *eid = 0;

    gpio_set_function(cs_pin, GPIO_FUNC_XIP_CS1);

    uint32_t intr_stash = save_and_disable_interrupts();

    qmi_hw->direct_csr = 30u << QMI_DIRECT_CSR_CLKDIV_LSB | QMI_DIRECT_CSR_EN_BITS;
    if (!wait_busy_clear()) goto fail;

    // Exit QPI to read ID using single-bit SPI command sequence.
    qmi_hw->direct_csr |= QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
    qmi_hw->direct_tx = QMI_DIRECT_TX_OE_BITS | (QMI_DIRECT_TX_IWIDTH_VALUE_Q << QMI_DIRECT_TX_IWIDTH_LSB) | PSRAM_CMD_QUAD_END;
    if (!wait_busy_clear()) goto fail;

    if ((qmi_hw->direct_csr & QMI_DIRECT_CSR_RXEMPTY_BITS) == 0) {
        (void)qmi_hw->direct_rx;
    }
    qmi_hw->direct_csr &= ~QMI_DIRECT_CSR_ASSERT_CS1N_BITS;

    qmi_hw->direct_csr |= QMI_DIRECT_CSR_ASSERT_CS1N_BITS;
    for (uint32_t i = 0; i < 7; ++i) {
        if (!wait_tx_not_full()) goto fail;
        qmi_hw->direct_tx = (i == 0) ? PSRAM_CMD_READ_ID : PSRAM_CMD_NOOP;
        if (!wait_rx_not_empty()) goto fail;

        unsigned int rx = qmi_hw->direct_rx & 0xffu;
        if (i == 5) *kgd = rx;
        if (i == 6) *eid = rx;
    }

    qmi_hw->direct_csr &= ~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS);
    restore_interrupts(intr_stash);
    return 1;

fail:
    qmi_hw->direct_csr &= ~(QMI_DIRECT_CSR_ASSERT_CS1N_BITS | QMI_DIRECT_CSR_EN_BITS);
    restore_interrupts(intr_stash);
    return 0;
}
