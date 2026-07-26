#pragma once
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <math.h>

// Thousands-grouped value. Decimals: 0 for >=1000, 2 for >=10, else 4
// (18026 => "18,026", 52.18 => "52.18", FX majors like 1.0856 => "1.0856").
static inline void fmt_value(char* buf, size_t n, double v) {
  int dec = (fabs(v) >= 1000.0) ? 0 : (fabs(v) >= 10.0 ? 2 : 4);
  char raw[32]; snprintf(raw, sizeof(raw), "%.*f", dec, v);
  char* dot = strchr(raw, '.');
  int int_len = dot ? (int)(dot - raw) : (int)strlen(raw);
  int neg = raw[0] == '-';
  int digits = int_len - neg;
  char out[40]; int o = 0;
  for (int i = 0; i < int_len; i++) {
    int pos = i - neg;                       // digit index within the number
    if (pos > 0 && (digits - pos) % 3 == 0) out[o++] = ',';
    out[o++] = raw[i];
  }
  if (dot) { while (*dot) out[o++] = *dot++; }
  out[o] = 0;
  snprintf(buf, n, "%s", out);
}

// Dollar figure: "$" + fmt_value's grouping/decimal rules (RIN quotes, index levels, ETF prices).
// Used where the number IS money; leave fmt_value bare for unitless things like humidity or volume.
static inline void fmt_usd(char* buf, size_t n, double v) {
  char raw[40]; fmt_value(raw, sizeof(raw), v);
  snprintf(buf, n, "$%s", raw);
}

// Temperature display. The weather record stores CELSIUS -- that is what Open-Meteo returns and what
// `weather_rec_t.temp_c` claims -- so the unit conversion is a display concern and lives here. Keeping
// the record canonical means a future metric/imperial toggle changes only this helper, not the fetch
// path or the stored schema.
static inline double temp_f(double c) { return c * 9.0 / 5.0 + 32.0; }

// Fahrenheit, whole degrees + degree sign (UTF-8 0xC2 0xB0, present in every display/body/mono
// subset). Whole degrees because a tenth of a degree F is below what the reading is worth.
static inline void fmt_temp(char* buf, size_t n, double celsius) {
  snprintf(buf, n, "%.0f\xC2\xB0", temp_f(celsius));
}

// Signed change: glyph (^ up / v down / - flat) + abs percent, e.g. "^ 0.12%".
// Returns: +1 up, -1 down, 0 flat (caller picks up/down/dim color).
static inline int fmt_change(char* buf, size_t n, double pct) {
  const char* g = pct > 0 ? "^" : (pct < 0 ? "v" : "-");
  snprintf(buf, n, "%s %.2f%%", g, fabs(pct));
  return pct > 0 ? 1 : (pct < 0 ? -1 : 0);
}
