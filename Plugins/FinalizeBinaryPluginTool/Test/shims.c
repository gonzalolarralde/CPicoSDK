#include <errno.h>
#include <stddef.h>
#include <malloc.h>   // for memalign

int posix_memalign(void **memptr, size_t alignment, size_t size) {
    // memptr must be non-NULL
    if (memptr == NULL) {
        return EINVAL;
    }

    // alignment must be a power of two and a multiple of sizeof(void*)
    if ((alignment & (alignment - 1)) != 0 || alignment < sizeof(void *)) {
        return EINVAL;
    }

    void *p = memalign(alignment, size);
    if (p == NULL) {
        *memptr = NULL;
        return ENOMEM;
    }

    *memptr = p;
    return 0;
}
