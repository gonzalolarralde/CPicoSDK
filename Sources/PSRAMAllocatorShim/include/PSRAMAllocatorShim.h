#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Returns 1 on success, 0 on timeout/failure.
// kgd/eid are valid only when success is returned.
int psram_probe_id_cshim(unsigned int cs_pin, unsigned int *kgd, unsigned int *eid);

#ifdef __cplusplus
}
#endif
