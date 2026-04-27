#pragma once

// Make newlib stdatomic module-safe by ensuring fixed-width integer typedefs
// are available before forwarding.
#include <stddef.h>
#include <stdint.h>
#include <inttypes.h>

#include_next <stdatomic.h>
