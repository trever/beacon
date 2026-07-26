#include "fetch/parse_series.h"
#include <ArduinoJson.h>

data_err_t parse_series(const char* json, size_t len, series_rec_t* out) {
  // Filter to just the two branches we read. The raw body also carries the timestamp array and several
  // unused indicator series; materializing those would multiply the document for nothing.
  JsonDocument filter;
  filter["chart"]["result"][0]["meta"]["regularMarketPrice"] = true;
  filter["chart"]["result"][0]["meta"]["previousClose"] = true;
  filter["chart"]["result"][0]["meta"]["chartPreviousClose"] = true;
  filter["chart"]["result"][0]["indicators"]["quote"][0]["close"] = true;

  JsonDocument doc;
  if (deserializeJson(doc, json, len, DeserializationOption::Filter(filter))) return ERR_PARSE;
  JsonObjectConst res = doc["chart"]["result"][0];
  if (res.isNull()) return ERR_PARSE;
  JsonArrayConst closes = res["indicators"]["quote"][0]["close"];
  if (closes.isNull()) return ERR_PARSE;

  out->count = 0;
  out->lo = 0; out->hi = 0;
  bool first = true;
  for (JsonVariantConst c : closes) {
    if (c.isNull()) continue;             // gap bucket: skip, never zero-fill (would flatten the chart)
    if (out->count >= SERIES_MAX) break;  // keep the OLDEST window; the tail is what meta.last covers
    float f = c.as<float>();
    out->v[out->count++] = f;
    if (first) { out->lo = out->hi = f; first = false; }
    else { if (f < out->lo) out->lo = f; if (f > out->hi) out->hi = f; }
  }
  if (out->count == 0) return ERR_PARSE;  // a series with no usable point is not a series

  JsonObjectConst meta = res["meta"];
  // meta.regularMarketPrice is authoritative for "now" -- the last close bucket can lag it by minutes.
  out->last = meta["regularMarketPrice"].isNull() ? (double)out->v[out->count - 1]
                                                  : meta["regularMarketPrice"].as<double>();
  JsonVariantConst pc = meta["previousClose"];
  if (pc.isNull()) pc = meta["chartPreviousClose"];   // Yahoo varies by symbol/session
  out->prev_close = pc.isNull() ? out->last : pc.as<double>();
  return ERR_NONE;
}
