#include "fetch/parse_ice.h"
#include <ArduinoJson.h>
#include <string.h>

// Copy into a fixed dst[cap], truncating to cap-1 + NUL (records.h string rule).
static void copy_trunc(char* dst, size_t cap, const char* src) {
  if (!src) { dst[0] = '\0'; return; }
  size_t n = strnlen(src, cap - 1);
  memcpy(dst, src, n);
  dst[n] = '\0';
}

data_err_t parse_ice(const char* json, size_t len, ice_rec_t* out) {
  JsonDocument doc;
  if (deserializeJson(doc, json, len)) return ERR_PARSE;
  JsonArrayConst arr = doc.as<JsonArrayConst>();
  if (arr.isNull()) return ERR_PARSE;   // root must be the contract array

  out->count = 0;
  for (JsonVariantConst row : arr) {
    if (out->count >= ICE_CONTRACTS_MAX) break;   // extras dropped; front months come first
    // A row with no usable price is skipped rather than rendered as 0.00 -- a zero print would read
    // as a real quote. ICE sends lastPrice 0 for a contract that has never traded.
    JsonVariantConst lp = row["lastPrice"];
    if (lp.isNull()) continue;
    double last = lp.as<double>();
    if (last == 0.0) continue;

    ice_contract_t* c = &out->c[out->count];
    copy_trunc(c->strip, ICE_STRIP_LEN, row["marketStrip"].as<const char*>());
    c->last = last;
    c->change_pct = row["change"] | 0.0;   // already a percent on the wire
    c->volume = row["volume"] | (uint32_t)0;
    copy_trunc(c->last_time, ICE_TIME_LEN, row["lastTime"].as<const char*>());
    out->count++;
  }
  return ERR_NONE;   // an empty/all-skipped array is "nothing listed", not a parse failure
}
