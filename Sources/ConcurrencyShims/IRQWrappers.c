#include "ConcurrencyShims.h"
#include <stddef.h>
#include <stdint.h>

extern void _cpicosdk_record_runtime_scheduler_enter_interrupt(uintptr_t core, uintptr_t interrupt);
extern void _cpicosdk_record_runtime_scheduler_exit_interrupt(uintptr_t core, uintptr_t interrupt);

typedef void (*cshims_irq_handler_fn_t)(void);

enum {
    CSHIMS_CORE_COUNT = 2,
    CSHIMS_IRQ_WRAPPER_COUNT = 64,
};

static cshims_irq_handler_fn_t cshims_irq_wrapper_originals[CSHIMS_CORE_COUNT][CSHIMS_IRQ_WRAPPER_COUNT] = {{0}};

static unsigned int cshims_current_core(void) {
    volatile uint32_t *const sio_cpuid = (volatile uint32_t *)0xD0000000u;
    return *sio_cpuid & 1u;
}

static cshims_irq_handler_fn_t *cshims_get_irq_vector_table(void) {
    // Current core's ARMv8-M VTOR register (SCB->VTOR).
    volatile uintptr_t *const vtor = (volatile uintptr_t *)0xE000ED08u;
    uintptr_t table = *vtor;
    if ((table & 0xF0000000u) != 0x20000000u) {
        // RP2xxx SRAM lives at 0x20000000...; refuse raw writes if VTOR points elsewhere.
        return NULL;
    }
    return (cshims_irq_handler_fn_t *)table;
}

void cshims_set_irq_wrapper_original(unsigned int irq, void (*handler)(void)) {
    if (irq >= CSHIMS_IRQ_WRAPPER_COUNT) {
        return;
    }
    cshims_irq_wrapper_originals[cshims_current_core()][irq] = handler;
}

void (*cshims_get_irq_vtor_handler(unsigned int irq))(void) {
    if (irq >= CSHIMS_IRQ_WRAPPER_COUNT) {
        return NULL;
    }

    cshims_irq_handler_fn_t *const vectorTable = cshims_get_irq_vector_table();
    if (vectorTable == NULL) {
        return NULL;
    }
    return vectorTable[16u + irq];
}

void cshims_set_irq_vtor_handler(unsigned int irq, void (*handler)(void)) {
    if (irq >= CSHIMS_IRQ_WRAPPER_COUNT) {
        return;
    }

    cshims_irq_handler_fn_t *const vectorTable = cshims_get_irq_vector_table();
    if (vectorTable == NULL) {
        return;
    }
    vectorTable[16u + irq] = handler;
}

static void cshims_irq_wrapper_dispatch(uint32_t irq) {
    if (irq >= CSHIMS_IRQ_WRAPPER_COUNT) {
        return;
    }

    const unsigned int core = cshims_current_core();
    _cpicosdk_record_runtime_scheduler_enter_interrupt(core, irq);

    cshims_irq_handler_fn_t original = cshims_irq_wrapper_originals[core][irq];
    if (original != NULL) {
        original();
    }

    _cpicosdk_record_runtime_scheduler_exit_interrupt(core, irq);
}

#define CSHIMS_DEFINE_IRQ_WRAPPER(N) \
    static void cshims_irq_wrapper_##N(void) { cshims_irq_wrapper_dispatch(N); }

CSHIMS_DEFINE_IRQ_WRAPPER(0)
CSHIMS_DEFINE_IRQ_WRAPPER(1)
CSHIMS_DEFINE_IRQ_WRAPPER(2)
CSHIMS_DEFINE_IRQ_WRAPPER(3)
CSHIMS_DEFINE_IRQ_WRAPPER(4)
CSHIMS_DEFINE_IRQ_WRAPPER(5)
CSHIMS_DEFINE_IRQ_WRAPPER(6)
CSHIMS_DEFINE_IRQ_WRAPPER(7)
CSHIMS_DEFINE_IRQ_WRAPPER(8)
CSHIMS_DEFINE_IRQ_WRAPPER(9)
CSHIMS_DEFINE_IRQ_WRAPPER(10)
CSHIMS_DEFINE_IRQ_WRAPPER(11)
CSHIMS_DEFINE_IRQ_WRAPPER(12)
CSHIMS_DEFINE_IRQ_WRAPPER(13)
CSHIMS_DEFINE_IRQ_WRAPPER(14)
CSHIMS_DEFINE_IRQ_WRAPPER(15)
CSHIMS_DEFINE_IRQ_WRAPPER(16)
CSHIMS_DEFINE_IRQ_WRAPPER(17)
CSHIMS_DEFINE_IRQ_WRAPPER(18)
CSHIMS_DEFINE_IRQ_WRAPPER(19)
CSHIMS_DEFINE_IRQ_WRAPPER(20)
CSHIMS_DEFINE_IRQ_WRAPPER(21)
CSHIMS_DEFINE_IRQ_WRAPPER(22)
CSHIMS_DEFINE_IRQ_WRAPPER(23)
CSHIMS_DEFINE_IRQ_WRAPPER(24)
CSHIMS_DEFINE_IRQ_WRAPPER(25)
CSHIMS_DEFINE_IRQ_WRAPPER(26)
CSHIMS_DEFINE_IRQ_WRAPPER(27)
CSHIMS_DEFINE_IRQ_WRAPPER(28)
CSHIMS_DEFINE_IRQ_WRAPPER(29)
CSHIMS_DEFINE_IRQ_WRAPPER(30)
CSHIMS_DEFINE_IRQ_WRAPPER(31)
CSHIMS_DEFINE_IRQ_WRAPPER(32)
CSHIMS_DEFINE_IRQ_WRAPPER(33)
CSHIMS_DEFINE_IRQ_WRAPPER(34)
CSHIMS_DEFINE_IRQ_WRAPPER(35)
CSHIMS_DEFINE_IRQ_WRAPPER(36)
CSHIMS_DEFINE_IRQ_WRAPPER(37)
CSHIMS_DEFINE_IRQ_WRAPPER(38)
CSHIMS_DEFINE_IRQ_WRAPPER(39)
CSHIMS_DEFINE_IRQ_WRAPPER(40)
CSHIMS_DEFINE_IRQ_WRAPPER(41)
CSHIMS_DEFINE_IRQ_WRAPPER(42)
CSHIMS_DEFINE_IRQ_WRAPPER(43)
CSHIMS_DEFINE_IRQ_WRAPPER(44)
CSHIMS_DEFINE_IRQ_WRAPPER(45)
CSHIMS_DEFINE_IRQ_WRAPPER(46)
CSHIMS_DEFINE_IRQ_WRAPPER(47)
CSHIMS_DEFINE_IRQ_WRAPPER(48)
CSHIMS_DEFINE_IRQ_WRAPPER(49)
CSHIMS_DEFINE_IRQ_WRAPPER(50)
CSHIMS_DEFINE_IRQ_WRAPPER(51)
CSHIMS_DEFINE_IRQ_WRAPPER(52)
CSHIMS_DEFINE_IRQ_WRAPPER(53)
CSHIMS_DEFINE_IRQ_WRAPPER(54)
CSHIMS_DEFINE_IRQ_WRAPPER(55)
CSHIMS_DEFINE_IRQ_WRAPPER(56)
CSHIMS_DEFINE_IRQ_WRAPPER(57)
CSHIMS_DEFINE_IRQ_WRAPPER(58)
CSHIMS_DEFINE_IRQ_WRAPPER(59)
CSHIMS_DEFINE_IRQ_WRAPPER(60)
CSHIMS_DEFINE_IRQ_WRAPPER(61)
CSHIMS_DEFINE_IRQ_WRAPPER(62)
CSHIMS_DEFINE_IRQ_WRAPPER(63)

static const cshims_irq_handler_fn_t cshims_irq_wrappers[] = {
    cshims_irq_wrapper_0,
    cshims_irq_wrapper_1,
    cshims_irq_wrapper_2,
    cshims_irq_wrapper_3,
    cshims_irq_wrapper_4,
    cshims_irq_wrapper_5,
    cshims_irq_wrapper_6,
    cshims_irq_wrapper_7,
    cshims_irq_wrapper_8,
    cshims_irq_wrapper_9,
    cshims_irq_wrapper_10,
    cshims_irq_wrapper_11,
    cshims_irq_wrapper_12,
    cshims_irq_wrapper_13,
    cshims_irq_wrapper_14,
    cshims_irq_wrapper_15,
    cshims_irq_wrapper_16,
    cshims_irq_wrapper_17,
    cshims_irq_wrapper_18,
    cshims_irq_wrapper_19,
    cshims_irq_wrapper_20,
    cshims_irq_wrapper_21,
    cshims_irq_wrapper_22,
    cshims_irq_wrapper_23,
    cshims_irq_wrapper_24,
    cshims_irq_wrapper_25,
    cshims_irq_wrapper_26,
    cshims_irq_wrapper_27,
    cshims_irq_wrapper_28,
    cshims_irq_wrapper_29,
    cshims_irq_wrapper_30,
    cshims_irq_wrapper_31,
    cshims_irq_wrapper_32,
    cshims_irq_wrapper_33,
    cshims_irq_wrapper_34,
    cshims_irq_wrapper_35,
    cshims_irq_wrapper_36,
    cshims_irq_wrapper_37,
    cshims_irq_wrapper_38,
    cshims_irq_wrapper_39,
    cshims_irq_wrapper_40,
    cshims_irq_wrapper_41,
    cshims_irq_wrapper_42,
    cshims_irq_wrapper_43,
    cshims_irq_wrapper_44,
    cshims_irq_wrapper_45,
    cshims_irq_wrapper_46,
    cshims_irq_wrapper_47,
    cshims_irq_wrapper_48,
    cshims_irq_wrapper_49,
    cshims_irq_wrapper_50,
    cshims_irq_wrapper_51,
    cshims_irq_wrapper_52,
    cshims_irq_wrapper_53,
    cshims_irq_wrapper_54,
    cshims_irq_wrapper_55,
    cshims_irq_wrapper_56,
    cshims_irq_wrapper_57,
    cshims_irq_wrapper_58,
    cshims_irq_wrapper_59,
    cshims_irq_wrapper_60,
    cshims_irq_wrapper_61,
    cshims_irq_wrapper_62,
    cshims_irq_wrapper_63,
};

void (*cshims_get_irq_wrapper(unsigned int irq))(void) {
    const size_t wrapperCount = sizeof(cshims_irq_wrappers) / sizeof(cshims_irq_wrappers[0]);
    if (irq >= wrapperCount) {
        return NULL;
    }
    return cshims_irq_wrappers[irq];
}
