#pragma once
#include <stdint.h>
#include <stdbool.h>

// Pure button debounce + edge detection. No Arduino/GPIO -- host-tested; hal/buttons.cpp supplies the
// raw levels. Mechanical buttons chatter for a few ms on both edges, so a raw read is unusable for
// "advance one page": a single press would fire several times.
#ifdef __cplusplus
extern "C" {
#endif

#define BTN_STABLE_MS 25u   // contact chatter settles well inside this; still imperceptible to a human

typedef struct {
  bool     stable;      // current debounced level (true = pressed)
  bool     pending;     // most recent raw level, waiting to become stable
  uint32_t since_ms;    // when `pending` was first observed
  bool     primed;      // false until the first poll seeds the state
} btn_state_t;

// Feed a raw level; returns true exactly once per debounced PRESS (release edges return false).
//
// Edge-on-press rather than on-release: the press is when the user expects the page to move, and a
// release edge would also fire after a long-hold that some other handler already consumed.
//
// The first poll only seeds state and never reports a press -- a button held at boot (BOOT is also the
// download-mode pin) must not be read as a deliberate press.
static inline bool btn_poll(btn_state_t* b, bool raw_pressed, uint32_t now_ms) {
  if (!b->primed) {
    b->primed = true; b->stable = raw_pressed; b->pending = raw_pressed; b->since_ms = now_ms;
    return false;
  }
  if (raw_pressed != b->pending) {          // level moved: restart the settle window
    b->pending = raw_pressed;
    b->since_ms = now_ms;
    return false;
  }
  if (raw_pressed == b->stable) return false;                 // nothing new to confirm
  if ((uint32_t)(now_ms - b->since_ms) < BTN_STABLE_MS) return false;   // not settled yet
  b->stable = raw_pressed;
  return raw_pressed;                       // report only the press edge
}

#ifdef __cplusplus
}
#endif
