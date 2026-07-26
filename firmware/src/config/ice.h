#pragma once

// ICE D4 RIN futures endpoint (tech.md §10: no magic constants in logic).
//
// productId/hubId identify the D4 RIN product on ICE's public product guide; they are opaque ICE
// catalogue ids, not credentials, and the endpoint takes no auth. Sourced from the ice-tracker-bar
// app and re-verified live 2026-07-26 (HTTP 200, ~400 B, 2 contracts).
//
// If ICE renumbers the catalogue the request still 200s but returns [], which the screen shows as
// "no contracts" rather than an error -- check these ids first if the screen goes empty.
#define ICE_HOST           "www.ice.com"
#define ICE_CONTRACT_PATH  "/marketdata/api/productguide/charting/contract-data?productId=21781&hubId=24559"

// 60 s: the ice-tracker-bar app polls at 30 s, halved here because this is a battery device sharing
// one serialized TLS socket with weather + up to 16 tickers. RIN months often go hours between trades.
#define ICE_CADENCE_S      60u
