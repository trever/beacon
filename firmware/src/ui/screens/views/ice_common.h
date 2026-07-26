#pragma once
#include <lvgl.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>
#include "core/records.h"
#include "ui/fmt.h"
#include "ui/theme.h"

// Shared formatting for the ICE D4 RIN views. Layout stays per-theme (CONVENTIONS.md); only the
// string shaping lives here, because "what a D4 RIN quote reads like" is a data concern, not a
// design one, and seven copies of it would drift.

// Contract month: "Dec26" => "DEC '26" (mirrors the ice-tracker-bar menubar formatting).
static inline void ice_fmt_strip(char* buf, size_t n, const char* strip, bool upper) {
  const char* p = strip;
  char letters[8]; size_t li = 0;
  while (*p && isalpha((unsigned char)*p) && li < sizeof(letters) - 1) letters[li++] = *p++;
  letters[li] = '\0';
  if (upper) for (size_t i = 0; i < li; i++) letters[i] = (char)toupper((unsigned char)letters[i]);
  else       for (size_t i = 0; i < li; i++) letters[i] = (char)tolower((unsigned char)letters[i]);
  if (*p) snprintf(buf, n, "%s '%s", letters, p);
  else    snprintf(buf, n, "%s", letters);
}

// Price. RIN quotes sit near 2.something and trade in 0.0001 increments, so 4dp is the meaningful
// precision -- fmt_value already yields 4dp below 10.0, so this stays consistent with the finance rows.
static inline void ice_fmt_price(char* buf, size_t n, double v) { fmt_value(buf, n, v); }

// "07/24/2026 07:30 PM GMT" => "07/24 07:30 PM". The year is noise on a 466px screen and the zone is
// constant. Falls back to the raw string if the shape is not what we expect.
static inline void ice_fmt_last_time(char* buf, size_t n, const char* raw) {
  if (!raw || !raw[0]) { snprintf(buf, n, "--"); return; }
  int mo, da, yr, hh, mm; char ampm[3] = {0};
  if (sscanf(raw, "%d/%d/%d %d:%d %2s", &mo, &da, &yr, &hh, &mm, ampm) == 6)
    snprintf(buf, n, "%02d/%02d %02d:%02d %s", mo, da, hh, mm, ampm);
  else
    snprintf(buf, n, "%s", raw);
}

// Volume with thousands grouping, or "--" when the contract has not traded.
static inline void ice_fmt_volume(char* buf, size_t n, uint32_t vol) {
  if (vol == 0) { snprintf(buf, n, "--"); return; }
  fmt_value(buf, n, (double)vol);
}

// The headline contract (front month). NULL when nothing is listed -- callers render placeholders.
static inline const ice_contract_t* ice_front(const ice_rec_t* r) {
  return (r && r->count > 0) ? &r->c[0] : NULL;
}

// Colour for a signed change, using the theme's up/down/dim roles.
static inline lv_color_t ice_change_color(const beacon_theme_t* t, double pct) {
  return pct > 0 ? t->up : (pct < 0 ? t->down : t->ink_dim);
}
