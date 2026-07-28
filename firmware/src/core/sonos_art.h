#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "core/records.h"        // SONOS_TILE_BYTES, SONOS_ART_URL_LEN, sonos_art_rec_t
#include "core/screen_state.h"   // data_err_t

// Sonos album art -- device-side transport (WS-2, plan docs/plans/2026-07-27-sonos-album-art-plan.md
// §4 "WS-2", design docs/specs/2026-07-27-sonos-album-art-design.md §4). Owns the two PSRAM tile
// buffers, the pure decision surface for the cross-core swap protocol, and the one-job LAN-fetch queue
// that bridges hub_task (Core 0, parses "sart") to fetch_task (Core 0, actually downloads via
// core/net_lan.h). hub_task.cpp posts jobs here; fetch_task.cpp drives sonos_art_service() once per
// its 1 s loop; the "sonos" screen view (WS-3) reads sonos_art_buf()/ds_get_sonos_art() to blit.
//
// Split deliberately (plan §5 "How the two-buffer swap gets tested without LVGL"): everything in the
// "pure" section below is a function of integers only -- no Arduino, no LVGL, no allocation, no static
// state -- so [env:native] host-tests every one of design §4.3's swap rules directly, AND (via two
// std::threads racing the SAME core/datastore.cpp this repo already builds natively, guarded by the
// SAME ds_lock_t the device uses) the concurrency itself. Only the device-glue section at the bottom
// (PSRAM allocation specifics, the job queue, the actual LAN GET, posting sart_stat back to the hub) is
// fenced with #if !BEACON_NATIVE in sonos_art.cpp; sonos_art_buf()/sonos_art_alloc() are the two
// exceptions -- both compile and work on the host too (plain malloc there), specifically so the race
// test can allocate real buffers and hand real pointers to two competing threads.

#ifdef __cplusplus
extern "C" {
#endif

// ================================================================================================
// Layer 1 -- pure decision functions (plan §5 layer 1, ~12 cases). No state, no I/O, no side effects.
// Every one is host-tested in test/test_sonos_art/.
// ================================================================================================

// The buffer index Core 0 must write into: always the one NOT currently displayed (design §4.3 rule 2 --
// this structurally prevents a torn tile, since the write target is never the buffer being read).
// back_idx(0)==1, back_idx(1)==0, and back_idx(x) != x for both -- the PROPERTY, not just the values.
uint8_t sonos_art_back_idx(uint8_t front_idx);

// Design §4.3 rules 4/5: Core 0 must not begin writing the back buffer until Core 1's ack (`seen_gen`)
// has caught up to the currently published `gen`, OR ack_timeout_ms has elapsed since that publish --
// the timeout covers the "sonos" page not currently being built (nobody will ever ack, and nobody is
// reading the buffer either, so proceeding is safe). The default on any doubt is "do not start
// writing": this returns false at every point strictly before EITHER condition holds, true the instant
// either one does (an exact-3000ms boundary with no ack must return true -- inclusive, not exclusive).
bool sonos_art_may_write(uint32_t published_gen, uint32_t seen_gen,
                          uint32_t ms_since_publish, uint32_t ack_timeout_ms);

// D-2 (plan §3, records.h): `gen` is an opaque tile IDENTITY, never an ordering -- compare with `!=`,
// not `>` (the hub's in-memory gen counter resets on relaunch, so a numerically smaller gen can be a
// legitimate new tile). True means Core 1 must re-point the lv_img to buf[idx] and then write
// seen_gen = gen (the ack half of the swap protocol -- WS-3's job, do not skip it).
bool sonos_art_should_repoint(uint32_t rec_gen, uint32_t seen_gen);

// Design §4.3 rule 3 / §8 "Partial download": a downloaded tile is publishable ONLY when all three hold
// at once -- an HTTP 200, a Content-Length that matches the tile size EXACTLY (not merely <=), and
// exactly that many bytes actually received. Any other combination -- including a Content-Length that
// under-reports, which a naive `received >= content_length` check would wave through -- is a rejection.
bool sonos_art_length_ok(int http_status, long content_length, size_t received);

// Design §4.4 "latest-wins": at most one art job is ever held (queued-or-in-flight). A genuinely
// different gen supersedes whatever is pending (net_lan.cpp's abort_flag is what actually interrupts an
// in-flight download; this function only decides WHETHER to). Re-posting the SAME gen that is already
// pending/in-flight must NOT supersede -- an S1 the hub re-sends verbatim (e.g. a BLE retransmit) must
// not restart a download that is already correctly under way.
bool sonos_art_job_supersedes(uint32_t pending_gen, bool pending_present, uint32_t new_gen);

// Maps a data_err_t as returned by net_lan_get() onto the frozen sart_stat vocabulary (design §2.3):
// conn_refused / timeout / http / net. "size" (a sonos_art_length_ok rejection) and "no_wifi"
// (net_is_up() was false before any connect was even attempted) are NOT data_err_t outcomes and never
// round-trip through this function -- callers pass those two literals directly. timeout and
// conn_refused must never collapse onto the same string: they are precisely what a later workstream's
// Local Network row distinguishes (design §2.3, plan WS-4 required coverage).
const char* sonos_art_err_for(data_err_t e);

// ================================================================================================
// Layer 2 -- tile buffers. Compiled for BOTH native and device (plan §5 layer 2): the race test needs
// real, independently-addressable buffers on the host. Device: heap_caps_malloc(..., MALLOC_CAP_SPIRAM)
// x2. Native: plain malloc() x2. Never freed once allocated (design §4.2 -- no allocation in the
// steady state, so nothing to leak or fragment); a second sonos_art_alloc() call is a cheap no-op
// success (on_theme() rebuilds every page, so build() -- WS-3's -- can legitimately run more than once).
// ================================================================================================

// Allocate both tile buffers if not already allocated. Returns true if buffers are ready (either just
// allocated or already were); false only on a genuine allocation failure, in which case sonos_art_buf()
// keeps returning NULL forever and every subsequent job must be treated per D-9 (no fetch, no stat).
bool sonos_art_alloc(void);

// Raw pointer to tile buffer `idx` (0 or 1). NULL if sonos_art_alloc() was never called or failed.
// SONOS_TILE_BYTES (records.h) bytes are valid to read/write once non-NULL.
uint8_t* sonos_art_buf(uint8_t idx);

// ================================================================================================
// Layer 3 -- device job queue + service loop. Declared unconditionally (harmless; a declared-but-
// undefined C function costs nothing unless called) but DEFINED only under #if !BEACON_NATIVE in
// sonos_art.cpp -- the native test suite drives the race purely off sonos_art_buf()/sonos_art_alloc()
// plus the Layer 1 functions and datastore.h, and never calls any of these three.
// ================================================================================================

// hub_task.cpp calls this from on_frame() on an S1 ("sart" with a url). Posts (or, per
// sonos_art_job_supersedes, supersedes) the one held job. A job already IN FLIGHT (fetch_task.cpp is
// mid net_lan_get() for a DIFFERENT gen) is aborted -- its eventual return is discarded and it emits no
// sart_stat (design §4.4's silent withdraw); a job merely QUEUED (not yet started) is replaced outright,
// so the superseded gen is never even attempted. `url` is copied (SONOS_ART_URL_LEN, truncation-safe).
void sonos_art_post_job(uint32_t gen, const char* url);

// hub_task.cpp calls this from on_frame() on an S2 ("sart" with no url, or the toggle turning art off).
// Drops/aborts whatever job is pending (a stale in-flight download must not be allowed to publish AFTER
// an explicit clear -- that would resurrect art the hub just told the device to remove) and then clears
// the DataStore record via ds_clear_sonos_art(). Callers should use THIS, not ds_clear_sonos_art()
// directly, whenever a job might be in flight.
void sonos_art_clear(void);

// Called once per fetch_task.cpp 1 s tick (Core 0), unconditionally -- not gated on
// timekeep_has_time() (art needs no clock) and deliberately called even while net_is_up() is false, so
// that a job posted while WiFi is down can answer err:"no_wifi" on the very next tick WITHOUT attempting
// a connect (design §8) rather than sitting queued until WiFi happens to come back. Services at most one
// job per call (a single net_lan_get() may block this call for up to the 8 s hard-abort budget, which is
// fine -- run_slot()'s device fetches already block the same loop for comparable spans). No-op if no job
// is pending, or if sonos_art_buf() has no allocated buffers (D-9: no fetch, no sart_stat).
void sonos_art_service(void);

#ifdef __cplusplus
}
#endif
