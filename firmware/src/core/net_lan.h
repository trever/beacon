#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "core/screen_state.h"   // data_err_t

// Plain-HTTP LAN GET straight into a caller buffer -- no TLS (design docs/specs/2026-07-27-sonos-
// album-art-design.md §4.1). A WiFiClientSecure handshake costs a ~40-50KB internal-heap spike
// (net.cpp:21) against a 46,428 B observed floor; the hub's LanAssetServer lives on the same LAN as the
// device by construction, so there is nothing to certificate-validate on this hop. OTA's WS-2 later
// extends this file with a streaming variant that feeds Update.write() instead of a flat buffer -- keep
// every testable decision (the swap protocol, the length check, the error-vocabulary mapping) in
// core/sonos_art.{h,cpp} instead of here, so this stays "a thin socket loop with nothing to unit-test"
// (plan §4 WS-2) and net_lan.cpp is deliberately absent from [env:native]'s build_src_filter.

#ifdef __cplusplus
extern "C" {
#endif

// GET `url` (the ONLY shape hub_parse_sart ever hands out: "http://<ipv4>:<port>/a/<32 hex>",
// records.h SONOS_ART_URL_LEN caps it at 96 chars) and, on success, leave exactly `expect_len` bytes in
// `out`. Reads AT MOST expect_len bytes into `out` regardless of what Content-Length claims -- a lying
// header can never overrun the caller's buffer (design §8 "Art larger than expected"). Reads straight
// off the socket into `out` with zero staging bytes (design §4.1) -- `out` is expected to be a PSRAM
// tile buffer already sized to hold expect_len bytes.
//
// Returns ERR_NONE only when ALL of {HTTP 200, Content-Length == expect_len, expect_len bytes actually
// received} hold -- the same three-part test sonos_art_length_ok() checks in isolation (this function
// applies it internally so net_lan.cpp itself needs no host test). On any other outcome, *err_out is set
// to one of the frozen sart_stat values (design §2.3): "conn_refused" (connect failed fast -- a RST-
// shaped rejection, e.g. the hub's firewall), "timeout" (connect or a read stalled to its deadline with
// nothing/incomplete data -- the TCC-denial shape), "http" (a non-200 status), "size" (a Content-Length
// or received-byte-count mismatch caught before or during the body read), or "net" (anything else). The
// return's data_err_t is a coarser category for logging only -- callers should prefer *err_out.
//
// *abort_flag is polled on every socket read (design §4.4 "latest-wins"): the caller (sonos_art.cpp)
// sets it the instant a newer gen supersedes this job. On an abort mid-transfer the return value and
// *err_out are UNSPECIFIED -- the caller MUST check *abort_flag itself before inspecting either, and
// must send NO sart_stat at all for a superseded job (CONTRACT.md §D's silent-withdraw precedent).
// abort_flag may be NULL (no supersede check -- not used by any current caller, but kept optional).
//
// Deadlines (design §4.5): connect ~3 s, per-read idle 3 s, overall hard abort 8 s. Every blocking wait
// is gated on available() + a cooperative yield (net.cpp's #92 pattern) so a stalled body never starves
// the Core-0 task watchdog. Safe to call only from the Core-0 fetch task (mirrors net_https_get).
data_err_t net_lan_get(const char* url, uint8_t* out, size_t expect_len,
                       const char** err_out, volatile bool* abort_flag);

#ifdef __cplusplus
}
#endif
