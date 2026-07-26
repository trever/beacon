#pragma once
#include <lvgl.h>
#include <stdint.h>
#include <stdbool.h>
#include <math.h>
#include "ui/theme.h"

// Value-change flash: when a tracked number moves, its label flashes the up/down colour and decays
// back to the resting colour. Gives a glanceable "something just ticked" cue on an ambient display.
//
// State is per tracked value, owned by the caller (a file-static in the view), because views are
// rebuilt on demand and a global registry would carry stale pointers across a rebuild.
//
// The caller drives this from update(), which runs on the 500 ms carousel tick -- so the flash decays
// over ticks, not frames. FLASH_MS is a small multiple of that period; anything shorter than one tick
// could be skipped entirely between updates and never be seen.
#define TICK_FLASH_MS 1500u

typedef struct {
  double   prev;        // last observed value
  bool     has_prev;    // false until the first observation, so a first paint never flashes
  int8_t   dir;         // +1 / -1 direction of the flash in progress; 0 = none
  uint32_t started_ms;  // lv_tick_get() when the flash began
} tick_flash_t;

// Feed the current value; returns the colour the label should use right now.
// `resting` is what to show when no flash is active (normally t->ink, or t->ink_dim when stale).
//
// A first observation never flashes: on boot every record transitions from placeholder to its first
// real value, and flashing the whole screen green at once would be noise, not signal.
static inline lv_color_t tick_flash_color(tick_flash_t* f, double value,
                                          const beacon_theme_t* t, lv_color_t resting) {
  if (!f->has_prev) {
    f->prev = value; f->has_prev = true; f->dir = 0;
    return resting;
  }
  // Exact compare is right here: these are quotes we want to react to at their own precision, and an
  // epsilon would swallow the 0.0001 increments RIN actually trades in.
  if (value != f->prev) {
    f->dir = (value > f->prev) ? 1 : -1;
    f->started_ms = lv_tick_get();
    f->prev = value;
  }
  if (f->dir != 0) {
    if (lv_tick_elaps(f->started_ms) < TICK_FLASH_MS)
      return f->dir > 0 ? t->up : t->down;
    f->dir = 0;   // decayed
  }
  return resting;
}

// Forget the tracked value, so the next observation is treated as a first paint and does not flash.
// Call when the source goes non-live: the value on screen is no longer a live tick, and coming back
// from OFFLINE/STALE would otherwise flash a "change" that is really just the link returning.
static inline void tick_flash_reset(tick_flash_t* f) {
  f->has_prev = false; f->dir = 0;
}
