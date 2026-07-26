#pragma once
#include <stdint.h>

// Physical side buttons (docs/research 2026-06-05 §pinout: PWR via AXP2101, BOOT, user GPIO18).
// PWR is owned by the PMU (long-hold powers off) and is deliberately NOT read here.
#ifdef __cplusplus
extern "C" {
#endif

#define BTN_EVT_PREV 0x01   // BOOT / GPIO0
#define BTN_EVT_NEXT 0x02   // user / GPIO18

void    buttons_begin(void);
uint8_t buttons_poll(void);   // debounced press edges as a BTN_EVT_* bitmask; call every loop()

#ifdef __cplusplus
}
#endif
