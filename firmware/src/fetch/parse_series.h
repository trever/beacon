#pragma once
#include <stddef.h>
#include "core/records.h"

// Parse a Yahoo chart response into an intraday series. Pure + host-testable; does NOT touch out->hdr
// or out->id (the caller owns those). Returns ERR_PARSE on malformed JSON or a missing close array.
//
// Yahoo interleaves `null` closes for gaps (halts, pre-open buckets). Nulls are SKIPPED rather than
// zero-filled: a 0.0 would collapse the chart's y-range and flatten the whole line.
#ifdef __cplusplus
extern "C" {
#endif
data_err_t parse_series(const char* json, size_t len, series_rec_t* out);
#ifdef __cplusplus
}
#endif
