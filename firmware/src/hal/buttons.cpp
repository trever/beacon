#include "hal/buttons.h"
#include "core/button.h"
#include "config/pins.h"
#include "util/log.h"
#include <Arduino.h>

// Both buttons are wired to ground with a pull-up, so a press reads LOW. INPUT_PULLUP keeps that true
// even on the user pin if the board has no external resistor.
//
// PIN_BTN_PREV is GPIO0, which is ALSO the download-mode strap: held during reset the chip enters the
// bootloader instead of the app. That only affects reset, so runtime use is safe -- and btn_poll never
// reports a press from the seeding poll, so a button held through boot cannot fire one.
static btn_state_t s_prev, s_next;

void buttons_begin(void) {
  pinMode(PIN_BTN_PREV, INPUT_PULLUP);
  pinMode(PIN_BTN_NEXT, INPUT_PULLUP);
  // Log the resting levels once: if a pin idles LOW the polarity assumption above is wrong for this
  // board revision and every poll would look like a held press.
  LOGI("buttons: prev(gpio%d)=%d next(gpio%d)=%d (expect 1 = released)",
       PIN_BTN_PREV, digitalRead(PIN_BTN_PREV), PIN_BTN_NEXT, digitalRead(PIN_BTN_NEXT));
}

uint8_t buttons_poll(void) {
  uint32_t now = millis();
  uint8_t evt = 0;
  if (btn_poll(&s_prev, digitalRead(PIN_BTN_PREV) == LOW, now)) evt |= BTN_EVT_PREV;
  if (btn_poll(&s_next, digitalRead(PIN_BTN_NEXT) == LOW, now)) evt |= BTN_EVT_NEXT;
  if (evt) LOGI("buttons: evt=0x%02X", evt);
  return evt;
}
