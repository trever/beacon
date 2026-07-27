#pragma once
#include <stdint.h>
#include "config/ticker_table.h"

// Per-source stale thresholds (tech.md §6 cadence table). Finance is per-ticker.
#define WEATHER_STALE_S    1800u   // 30 min
#define USAGE_STALE_S       300u   // 5 min / hub-offline
#define BUDDY_STALE_S       300u
#define SONOS_STALE_S       300u   // hub-plane, pushed on change; same class as usage/buddy
// ICE D4 RIN: polled every 60 s (matching the ice-tracker app's 30 s, halved for a battery device).
// Stale at 10 min -- generous because the CONTRACT can legitimately go days without a trade; this
// threshold is about OUR fetch being stale, and the per-contract last_time carries market liveness.
#define ICE_STALE_S         600u
// Graph series: polled at 5 min, stale at 15 -- three missed polls, so a single hiccup does not
// grey out a chart that is still perfectly readable.
#define SERIES_STALE_S      900u

// Read the per-row stale window from the RUNTIME table (hub-pushed or default), not DEFAULT_TICKERS:
// a config with rows beyond the default count would otherwise get stale_s=0 and be marked ST_STALE right
// after a successful fetch (#92).
static inline uint32_t finance_stale_s(uint8_t idx) {
  ticker_runtime_t t;
  return ticker_table_get((int)idx, &t) ? t.stale_s : 0u;
}
