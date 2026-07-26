#pragma once
#include <stdint.h>
// LVGL 8.4 port: one partial draw buffer (PSRAM), flush -> display, indev <- touch.
bool lvgl_port_begin();   // call after display_begin() + touch_begin()
// Pump from loop() on Core 1. Returns lv_timer_handler()'s hint: ms until LVGL next needs pumping.
// The caller MUST sleep by roughly that much (clamped) rather than a fixed delay -- during a swipe
// LVGL wants to be called back immediately, and a fixed 5 ms nap costs ~20% of frame throughput.
uint32_t lvgl_port_tick();
