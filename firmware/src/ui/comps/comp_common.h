#pragma once
#include <lvgl.h>
#include <stddef.h>
#include "ui/tick_flash.h"
#include "core/records.h"

// Shared construction + update helpers for the Home complication renderers (ui/comps/comp_*.cpp).
//
// Convergence sweep (docs/plans/2026-07-27-home-complications-plan.md §10 item 1): once all seven
// renderers existed side by side, four blocks turned out to be repeated verbatim rather than merely
// similar -- shape-A's three/four-widget build(), shape-B's icon+two-line build(), the value/status/
// trend tail comp_fin and comp_ice both run after their own "not configured"/"no contracts" early
// return, and the toupper-copy loop every arg/label render used. This header is PURE CODE MOTION: every
// call site below reproduces the exact widget tree, style, alignment and text that renderer used to
// build inline -- see comp_common.cpp's comment block for the byte-for-byte mapping back to the
// pre-extraction bodies. No renderer's on-screen behaviour changes; the local-offset table in
// comp_registry.h still governs every position and is unchanged.

// Shape-A build: name (S.slot, TOP_LEFT y18) / value (S.display, TOP_RIGHT y10) / change % (S.slot,
// TOP_RIGHT y40), matching comp_registry.h's offset table. `name_init` is the name label's initial
// text ("--" for fin/usage/weather's placeholder, "D4 RIN" for ice's fixed name). `icon` is the
// trend-glyph label used by fin/ice; pass NULL for usage/weather, which make no trend claim.
void comp_build_shape_a(lv_obj_t* slot, const char* name_init,
                        lv_obj_t** name, lv_obj_t** val, lv_obj_t** pct, lv_obj_t** icon);

// Shape-B build: icon (t->f_icon, TOP_LEFT y18) / line 1 (S.body, LONG_DOT, x26 y14) / line 2
// (S.slot, LONG_DOT, x26 y40), matching comp_registry.h's offset table. `icon_glyph` is the
// renderer's default icon codepoint (agents: ICON_BOT, sonos: ICON_ZAP) shown until the first update().
void comp_build_shape_b(lv_obj_t* slot, const char* icon_glyph,
                        lv_obj_t** icon, lv_obj_t** line1, lv_obj_t** line2);

// The value + status + trend tail comp_fin/comp_ice both run once their own "not configured"/"no
// contracts" branch has returned early: tick_flash-driven value colour (reset on non-live so the link
// merely returning never flashes), the sv_status short-circuit (state chip in `pct`, no trend claim),
// and otherwise the trend glyph + signed percent via fmt_change_num. `flash` stays a file-static owned
// by the caller (views/CONVENTIONS.md: state is per-instance, not per-call) -- this function only reads
// and mutates through the pointer.
void comp_render_market_row(lv_obj_t* val, lv_obj_t* pct, lv_obj_t* icon, tick_flash_t* flash,
                            const record_hdr_t* hdr, double value, double change_pct);

// Upper-cases `in` into `out` (NUL-terminated, capped at `cap`), stopping at the first NUL or a full
// buffer -- the toupper-copy loop repeated at comp_fin's ticker id, comp_usage's arg id + provider
// label, and comp_weather's WMO label. `in` may be NULL or empty; `out` is always terminated.
void comp_str_upper(char* out, size_t cap, const char* in);

// Whole-record non-live short-circuit shared by comp_usage/comp_weather: when `hdr` is not ST_LIVE,
// shows the state chip in `pct`, blanks `val`, sets `name` to the renderer's fallback label (e.g.
// "USAGE"/"WEATHER") and returns true -- the caller returns immediately, same as comp_fin/comp_ice's
// non-live branch inside comp_render_market_row (which additionally blanks a trend icon neither usage
// nor weather has). Returns false when the record IS live, in which case nothing was touched.
bool comp_render_status_row(lv_obj_t* name, lv_obj_t* val, lv_obj_t* pct,
                            const char* name_text, const record_hdr_t* hdr);
