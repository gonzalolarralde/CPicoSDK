#pragma once

#if __has_include("CPicoSDK_pimoroni_pico_plus2_w_rp2350.h")
#include "CPicoSDK_pimoroni_pico_plus2_w_rp2350.h"
#elif __has_include("CPicoSDK_pimoroni_pico_plus2_rp2350.h")
#include "CPicoSDK_pimoroni_pico_plus2_rp2350.h"
#elif __has_include("CPicoSDK_pico2_w.h")
#include "CPicoSDK_pico2_w.h"
#elif __has_include("CPicoSDK_pico2.h")
#include "CPicoSDK_pico2.h"
#elif __has_include("CPicoSDK_pico.h")
#include "CPicoSDK_pico.h"
#elif __has_include("CPicoSDK_pico_w.h")
#include "CPicoSDK_pico_w.h"
#else
#warning "No CPicoSDK board header available"
#include "CPicoSDK_pico2.h"
#endif
