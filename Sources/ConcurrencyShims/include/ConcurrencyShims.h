#ifndef CONCURRENCYSHIMS_H
#define CONCURRENCYSHIMS_H

#ifdef __cplusplus
extern "C" {
#endif

// Optional helper APIs for cooperative polling loops.
void cshims_run_job_bridge(void *job, void *executorFirst, void *executorSecond);
unsigned int cshims_enter_critical(void);
void cshims_exit_critical(unsigned int state);

typedef void (*cshims_irq_handler_t)(void);
cshims_irq_handler_t cshims_get_irq_wrapper(unsigned int irq);
void cshims_set_irq_wrapper_original(unsigned int irq, cshims_irq_handler_t handler);
cshims_irq_handler_t cshims_get_irq_vtor_handler(unsigned int irq);
void cshims_set_irq_vtor_handler(unsigned int irq, cshims_irq_handler_t handler);

#ifdef __cplusplus
}
#endif

#endif
