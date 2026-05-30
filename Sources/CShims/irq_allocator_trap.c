#include "CShims.h"

extern int stdio_puts_raw(const char *s) __attribute__((weak));

volatile uint32_t cshims_irq_allocator_operation = 0;
volatile uint32_t cshims_irq_allocator_exception = 0;
volatile uint32_t cshims_irq_allocator_core = 0;
static volatile uint32_t cshims_irq_allocator_warned = 0;

static inline uint32_t cshims_current_core(void) {
#if defined(__arm__) || defined(__thumb__)
    return *(volatile uint32_t *)0xd0000000u;
#else
    return 0;
#endif
}

__attribute__((section(".flashdata.irq_allocator")))
void cshims_record_irq_allocator_use(uint32_t operation, uint32_t exception) {
    cshims_irq_allocator_operation = operation;
    cshims_irq_allocator_exception = exception;
    cshims_irq_allocator_core = cshims_current_core() & 1u;
}

__attribute__((section(".flashdata.irq_allocator")))
void cshims_warn_irq_allocator_use(uint32_t operation, uint32_t exception) {
    cshims_record_irq_allocator_use(operation, exception);

    if (__atomic_exchange_n(&cshims_irq_allocator_warned, 1u, __ATOMIC_RELAXED) != 0u) {
        return;
    }

    if (stdio_puts_raw != 0) {
        stdio_puts_raw(
            "[CPicoSDK] malloc/calloc/realloc/free was called from IRQ context; "
            "move allocation/lifetime work out of the handler or enable the "
            "GuardIRQAllocations trait to trap at the call site.");
    }
}

__attribute__((section(".flashdata.irq_allocator")))
void cshims_irq_allocator_debug_break(void) {
#if defined(__arm__) || defined(__thumb__)
    __asm__ volatile("bkpt #0" ::: "memory");
#else
    __builtin_trap();
#endif
}
