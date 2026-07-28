#include "core/sonos_art.h"
#include <string.h>

// ================================================================================================
// Layer 1 -- pure decision functions. No Arduino, no LVGL, no allocation, no static state. See the
// header for what each one prevents; test/test_sonos_art/test_main.cpp exercises every case the plan
// requires (§5 layer 1's dozen-ish cases).
// ================================================================================================

uint8_t sonos_art_back_idx(uint8_t front_idx) {
  return front_idx == 0 ? 1 : 0;
}

bool sonos_art_may_write(uint32_t published_gen, uint32_t seen_gen,
                          uint32_t ms_since_publish, uint32_t ack_timeout_ms) {
  if (seen_gen == published_gen) return true;     // Core 1 has already acked this publish
  return ms_since_publish >= ack_timeout_ms;       // ... or the timeout covers an unbuilt/absent reader
}

bool sonos_art_should_repoint(uint32_t rec_gen, uint32_t seen_gen) {
  return rec_gen != seen_gen;   // D-2: identity, not ordering
}

bool sonos_art_length_ok(int http_status, long content_length, size_t received) {
  if (http_status != 200) return false;
  if (content_length != (long)SONOS_TILE_BYTES) return false;
  if (received != (size_t)SONOS_TILE_BYTES) return false;
  return true;
}

bool sonos_art_job_supersedes(uint32_t pending_gen, bool pending_present, uint32_t new_gen) {
  if (!pending_present) return true;      // nothing held yet -- any job supersedes "nothing"
  return pending_gen != new_gen;          // a genuinely different gen supersedes; an identical re-post does not
}

const char* sonos_art_err_for(data_err_t e) {
  switch (e) {
    case ERR_NO_ROUTE: return "conn_refused";
    case ERR_TIMEOUT:  return "timeout";
    case ERR_HTTP:     return "http";
    // ERR_NONE (success -- should never be mapped), ERR_RATE_LIMITED, ERR_PARSE: none of these are
    // reachable outcomes of net_lan_get() on the LAN path (rate limiting is a Yahoo/Binance concept; a
    // malformed-response parse failure collapses to the generic transport bucket). Defensive fallback.
    default: return "net";
  }
}

// ================================================================================================
// Layer 2 -- tile buffers. Compiled for both native and device; only the allocator call differs.
// ================================================================================================

static uint8_t* s_buf[2]     = { nullptr, nullptr };
static bool     s_alloc_done = false;   // true once an allocation attempt has run (success OR failure)
static bool     s_alloc_ok   = false;

#if BEACON_NATIVE
#include <stdlib.h>
static uint8_t* art_alloc_one(size_t n) { return (uint8_t*)malloc(n); }
#else
#include <esp_heap_caps.h>
static uint8_t* art_alloc_one(size_t n) { return (uint8_t*)heap_caps_malloc(n, MALLOC_CAP_SPIRAM); }
#endif

bool sonos_art_alloc(void) {
  if (s_alloc_done) return s_alloc_ok;   // idempotent: on_theme() rebuilds every page (THEME_COUNT==1
                                          // today, but write it correctly anyway -- plan trap)
  s_alloc_done = true;
  s_buf[0] = art_alloc_one(SONOS_TILE_BYTES);
  s_buf[1] = art_alloc_one(SONOS_TILE_BYTES);
  s_alloc_ok = (s_buf[0] != nullptr) && (s_buf[1] != nullptr);
  return s_alloc_ok;
}

uint8_t* sonos_art_buf(uint8_t idx) {
  return (idx < 2) ? s_buf[idx] : nullptr;
}

// ================================================================================================
// Layer 3 -- device job queue + service loop. Device only: touches FreeRTOS (the job-queue mutex),
// the hub link (hub_send_sart_stat, hub_task.h), net_is_up() (core/net.h) and net_lan_get()
// (core/net_lan.h, itself Arduino-coupled and NOT built natively -- see platformio.ini).
// ================================================================================================
#if !BEACON_NATIVE
#include "core/datastore.h"
#include "core/hub_task.h"   // hub_send_sart_stat
#include "core/net.h"        // net_is_up
#include "core/net_lan.h"    // net_lan_get
#include "util/log.h"
#include <Arduino.h>          // millis()
#include <freertos/FreeRTOS.h>
#include <freertos/semphr.h>

// The one held job (queued and/or in flight). Guarded by s_job_mtx because hub_task (Core 0, ~50 Hz)
// posts/clears it while fetch_task (Core 0, a DIFFERENT task, ~1 Hz) may be mid net_lan_get() for it --
// two separate FreeRTOS tasks pinned to the same core still preempt each other, so this is a genuine
// cross-task race, not a formality. `abort` is additionally `volatile` because net_lan_get() polls it
// directly (without the mutex) on every socket read, per design §4.4's "checked on every read" rule --
// a single aligned bool read/write needs no lock, which is the entire point of making it volatile
// instead of folding it into the mutex-guarded fields.
static struct {
  uint32_t      gen;
  char          url[SONOS_ART_URL_LEN];
  bool          present;      // a job is queued and/or being serviced
  bool          in_flight;    // sonos_art_service() has an active net_lan_get() call for `gen`
  volatile bool abort;        // set by a newer post_job()/clear() while in_flight
} s_job;

static SemaphoreHandle_t s_job_mtx = nullptr;
static uint32_t          s_last_publish_ms = 0;   // millis() at the most recent ds_publish_sonos_art()

static void job_lock(void)   { if (!s_job_mtx) s_job_mtx = xSemaphoreCreateMutex(); xSemaphoreTake(s_job_mtx, portMAX_DELAY); }
static void job_unlock(void) { xSemaphoreGive(s_job_mtx); }

void sonos_art_post_job(uint32_t gen, const char* url) {
  job_lock();
  if (!sonos_art_job_supersedes(s_job.gen, s_job.present, gen)) { job_unlock(); return; }   // identical re-post: no-op
  if (s_job.present && s_job.in_flight) s_job.abort = true;   // interrupt the download already under way
  s_job.gen = gen;
  if (url) { strncpy(s_job.url, url, SONOS_ART_URL_LEN - 1); s_job.url[SONOS_ART_URL_LEN - 1] = '\0'; }
  else       s_job.url[0] = '\0';
  s_job.present = true;
  job_unlock();
}

void sonos_art_clear(void) {
  job_lock();
  if (s_job.present) {
    if (s_job.in_flight) s_job.abort = true;   // a stale in-flight download must not publish after this clear
    s_job.present = false;
  }
  job_unlock();
  ds_clear_sonos_art();
}

void sonos_art_service(void) {
  job_lock();
  if (!s_job.present) { job_unlock(); return; }
  uint32_t gen = s_job.gen;
  char url[SONOS_ART_URL_LEN];
  strncpy(url, s_job.url, SONOS_ART_URL_LEN); url[SONOS_ART_URL_LEN - 1] = '\0';
  job_unlock();

  // Design §8 "Device WiFi down when art changes": answer immediately, without attempting a connect --
  // this is the net_is_up() gate design §4.5 requires, and it is why this function is called every
  // tick regardless of link state rather than nested inside fetch_task.cpp's own `if (up)` branch.
  if (!net_is_up()) {
    job_lock();
    bool same = s_job.present && s_job.gen == gen;
    if (same) s_job.present = false;
    job_unlock();
    if (same) hub_send_sart_stat(gen, false, "no_wifi");
    return;
  }

  // D-9-adjacent: no buffers means the "sonos" screen was never built (or allocation failed). Drop
  // silently -- no fetch, no sart_stat -- exactly like a sart frame arriving with no buffers allocated.
  sonos_art_rec_t rec = ds_get_sonos_art();
  uint8_t back = sonos_art_back_idx(rec.idx);
  uint8_t* buf = sonos_art_buf(back);
  if (!buf) {
    job_lock();
    if (s_job.present && s_job.gen == gen) s_job.present = false;
    job_unlock();
    return;
  }

  // Design §4.3 rules 4/5: do not start writing the back buffer until Core 1 has acked the current
  // publish, or the ack timeout has elapsed. Not yet safe => leave the job queued and retry next tick
  // (the ack normally lands within one 500 ms Core-1 tick, well under the 3000 ms timeout).
  uint32_t now_ms = millis();
  uint32_t elapsed = now_ms - s_last_publish_ms;   // unsigned wrap-safe
  if (!sonos_art_may_write(rec.gen, rec.seen_gen, elapsed, 3000)) return;

  job_lock();
  s_job.in_flight = true;
  s_job.abort = false;   // starting fresh for THIS gen -- any abort must postdate this point to count
  job_unlock();

  const char* err = nullptr;
  data_err_t derr = net_lan_get(url, buf, SONOS_TILE_BYTES, &err, &s_job.abort);

  job_lock();
  bool aborted = s_job.abort;
  bool same    = s_job.present && s_job.gen == gen;
  s_job.in_flight = false;
  if (same) s_job.present = false;   // this job is finished one way or another; a superseding job (if
                                      // any) already overwrote gen/url and stays present for next tick
  job_unlock();

  if (aborted) return;   // superseded mid-flight: CONTRACT.md §D silent withdraw -- no sart_stat at all

  if (derr == ERR_NONE) {
    ds_publish_sonos_art(gen, back);
    s_last_publish_ms = millis();
    hub_send_sart_stat(gen, true, nullptr);
    LOGI("sonos_art: gen=%u published idx=%u", (unsigned)gen, (unsigned)back);
  } else {
    hub_send_sart_stat(gen, false, err ? err : sonos_art_err_for(derr));
    LOGW("sonos_art: gen=%u failed err=%s", (unsigned)gen, err ? err : sonos_art_err_for(derr));
  }
}

#endif  // !BEACON_NATIVE
