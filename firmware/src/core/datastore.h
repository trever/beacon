#pragma once
#include <stdint.h>
#include "core/records.h"

// FROZEN API (FR-STATE-0). Thread-safe per tech.md §6: Core-0 fetchers write, Core-1 UI
// reads by-value snapshots; the lock only guards struct copies. Setters force the record
// to ST_LIVE / ERR_NONE on success (clearing any prior error/hub-offline). Callers stamp
// hdr.last_updated (they know the fetch time); the staleness sweep consumes it.

void datastore_init(void);   // seeds finance_count + ids from DEFAULT_TICKERS, all ST_LOADING

// Setters (Core-0). Copy value fields; force hdr.state=ST_LIVE, hdr.err=ERR_NONE.
void ds_set_weather(const weather_rec_t* r);
void ds_set_finance(uint8_t idx, const finance_rec_t* r);  // preserves the slot's seeded id
// Guarded publish (A5, stale-fetch race / design §3.3 Codex #1): a fetch captures the slot's id at
// start; this writes ONLY if slot idx still holds that id. After a hub reseed swaps the slot to a new
// id, an in-flight fetch that completes against the old id is DROPPED, not shown live. Else like ds_set_finance.
void ds_set_finance_if(uint8_t idx, const char* expect_id, const finance_rec_t* r);
void ds_set_ice(const ice_rec_t* r);   // ICE D4 RIN contract table (device-plane)
void ds_set_series(const series_rec_t* r);   // intraday series for the graph screen
void ds_set_usage(const usage_rec_t* r);
void ds_set_buddy(const buddy_rec_t* r);
void ds_set_sonos(const sonos_rec_t* r);   // Sonos now-playing (hub-plane, phase 1 text only)

// Sonos album art (D-3): a SEPARATE record from sonos_rec_t/ds_set_sonos, so an ordinary "sonos" text
// heartbeat can never touch it. ds_publish_sonos_art sets gen/idx/have verbatim -- no ordering check, no
// clamping (D-2: gen is an identity, compared by the caller with `!=`, not `>`). ds_clear_sonos_art (S2)
// sets ONLY have=false; it does not touch gen/idx/seen_gen. ds_sonos_art_seen is Core 1's ack after it
// re-points the lv_img to buf[idx] (the swap protocol's ack half, design §4.3 rule 4/5).
void ds_publish_sonos_art(uint32_t gen, uint8_t idx);
void ds_clear_sonos_art(void);
void ds_sonos_art_seen(uint32_t gen);

// Reseed the finance slots from a new ticker set (A5 live re-apply): set the new count and, per slot,
// the new id + ST_LOADING with value/change zeroed. Called after a validated hub config swap.
void ds_reseed_finance(const char ids[][FIN_ID_LEN], int count);

// Merge-only update for the sessions sub-record (sessions frame is independent of the buddy frame).
// Copies ONLY sessions[]/session_count into the stored buddy record; leaves all other fields (prompt,
// running, waiting, tokens, ...) intact. Stamps hdr.last_updated = now, sets ST_LIVE / ERR_NONE.
// count is clamped to BUDDY_SESSIONS_MAX.
void ds_apply_sessions(const buddy_session_t* s, uint8_t count, uint32_t now);

// Explicit failure/transport transitions (do NOT touch the value payload).
void ds_set_state_weather(screen_state_t s, data_err_t e);
void ds_set_state_ice(screen_state_t s, data_err_t e);
void ds_set_state_series(screen_state_t s, data_err_t e);
void ds_set_state_finance(uint8_t idx, screen_state_t s, data_err_t e);
void ds_set_state_sonos(screen_state_t s, data_err_t e);
void ds_set_hub_offline(void);   // flips usage + buddy + sonos to ST_HUB_OFFLINE

// Getters (Core-1). By-value snapshot under the lock.
weather_rec_t    ds_get_weather(void);
ice_rec_t        ds_get_ice(void);
series_rec_t     ds_get_series(void);
finance_rec_t    ds_get_finance(uint8_t idx);
uint8_t          ds_get_finance_count(void);
usage_rec_t      ds_get_usage(void);
buddy_rec_t      ds_get_buddy(void);
sonos_rec_t      ds_get_sonos(void);
sonos_art_rec_t  ds_get_sonos_art(void);

// Staleness sweep (~1/s from a Core-0 timer). For each record: if state==ST_LIVE and
// record_age_s(hdr, now) >= stale_s(source), promote to ST_STALE. Inclusive boundary.
// Never overwrites ST_OFFLINE / ST_ERROR / ST_HUB_OFFLINE (state-priority rule).
void ds_tick_staleness(uint32_t now);

// Buddy-prompt lifecycle tick (~1/s, Core-0). `now` is MONOTONIC uptime (uptime_s()), not wall clock.
// Mutates prompt only, never hdr.state, so it cannot erase ST_HUB_OFFLINE. Atomic under the lock:
// a SENT_OK beat past BUDDY_CONFIRM_HOLD_S clears (present=false); an undecided (IDLE) prompt past
// BUDDY_PROMPT_EXPIRY_S becomes PROMPT_TOO_LATE (reuses the dismiss affordance, no new state).
void ds_tick_buddy_prompt(uint32_t now);

// Tap-to-open feedback (issue #110, Phase 2). All three are device-local; NOT serialized.
// ds_set_open_pending: record that an "open" command was sent for session `id`.
// ds_apply_open_ack:   apply the hub's ack/err for `id`; no-ops if id doesn't match or state wrong.
// ds_tick_open:        advance feedback timeout; call alongside ds_tick_buddy_prompt each ~1s.
void ds_set_open_pending(const char* id, uint32_t now);
void ds_apply_open_ack(const char* id, bool ok, uint32_t now);
void ds_tick_open(uint32_t now);
