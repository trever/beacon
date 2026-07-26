#pragma once
#include <stddef.h>
#include "core/records.h"   // ice_rec_t, data_err_t (via screen_state.h)

// Parse ICE's product-guide contract-data JSON (a top-level ARRAY of contract objects) into an
// ice_rec_t's value fields. Pure + host-testable; does NOT touch out->hdr (the caller stamps
// state/time). Returns ERR_PARSE on malformed JSON or a non-array root, ERR_NONE otherwise.
//
// An empty array parses to count == 0 with ERR_NONE: the endpoint legitimately returns [] outside a
// listing window, which is "nothing listed", not a failure -- the screen shows placeholders rather
// than an error chip.
#ifdef __cplusplus
extern "C" {
#endif
data_err_t parse_ice(const char* json, size_t len, ice_rec_t* out);
#ifdef __cplusplus
}
#endif
