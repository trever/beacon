#include <unity.h>
#include <stdio.h>
#include <string.h>
#include <thread>
#include <atomic>
#include <chrono>
#include "core/sonos_art.h"
#include "core/datastore.h"
#include "core/records.h"
#include "core/screen_state.h"
#include "config/ticker_table.h"

// WS-2 (album art plan §4 "WS-2", §5 "How the two-buffer swap gets tested without LVGL"). Two layers:
//   Layer 1 -- the pure decision functions (sonos_art_back_idx / _may_write / _should_repoint /
//   _length_ok / _job_supersedes / _err_for): plain (integers) -> bool/uint8/const char*, no state.
//   Layer 2 -- the concurrency itself, natively, with two real std::threads racing the SAME
//   core/datastore.cpp this repo already builds for [env:native] (ds_lock_t is std::mutex on the host),
//   using the SAME sonos_art_buf()/sonos_art_alloc() the device build uses (plain malloc here instead
//   of heap_caps_malloc -- see sonos_art.cpp). A positive run (writer obeys sonos_art_may_write) must
//   see zero torn reads; a negative run (writer ignores it) must see > 0 -- proving the positive run is
//   not vacuous, per the plan's explicit requirement.

void setUp(void) { ticker_table_init(); datastore_init(); }
void tearDown(void) {}

// ============================================================================
// Layer 1: sonos_art_back_idx
// ============================================================================

static void test_back_idx_swaps_and_never_equals_input(void) {
  TEST_ASSERT_EQUAL_UINT8(1, sonos_art_back_idx(0));
  TEST_ASSERT_EQUAL_UINT8(0, sonos_art_back_idx(1));
  TEST_ASSERT_TRUE(sonos_art_back_idx(0) != 0);
  TEST_ASSERT_TRUE(sonos_art_back_idx(1) != 1);
}

// ============================================================================
// Layer 1: sonos_art_may_write (design §4.3 rules 4/5 -- "do not start writing" is the default)
// ============================================================================

static void test_may_write_false_before_ack_or_timeout(void) {
  // seen_gen (3) hasn't caught up to published_gen (4) yet, and only 500ms have passed -- must NOT write.
  TEST_ASSERT_FALSE(sonos_art_may_write(4, 3, 500, 3000));
  TEST_ASSERT_FALSE(sonos_art_may_write(4, 3, 2999, 3000));
}

static void test_may_write_true_at_exact_timeout_with_no_ack(void) {
  // The page-not-built case: nobody will ever ack. The boundary is inclusive.
  TEST_ASSERT_TRUE(sonos_art_may_write(4, 3, 3000, 3000));
  TEST_ASSERT_TRUE(sonos_art_may_write(4, 3, 5000, 3000));   // and anything past it
}

static void test_may_write_true_instantly_once_acked_regardless_of_elapsed(void) {
  TEST_ASSERT_TRUE(sonos_art_may_write(9, 9, 0, 3000));       // acked immediately, 0ms elapsed
  TEST_ASSERT_TRUE(sonos_art_may_write(9, 9, 1, 3000));
}

// ============================================================================
// Layer 1: sonos_art_should_repoint (D-2: identity, not ordering)
// ============================================================================

static void test_should_repoint_true_even_when_gen_is_numerically_smaller(void) {
  // D-2: a hub relaunch can hand the device a numerically SMALLER gen than one already seen. `!=` must
  // still flag it as needing a repoint; a `>` comparison would ignore it forever.
  TEST_ASSERT_TRUE(sonos_art_should_repoint(1, 7));
}

static void test_should_repoint_false_when_equal(void) {
  TEST_ASSERT_FALSE(sonos_art_should_repoint(7, 7));
}

// ============================================================================
// Layer 1: sonos_art_length_ok (design §4.3 rule 3 / §8 "Partial download")
// ============================================================================

static void test_length_ok_rejects_non_200_status(void) {
  TEST_ASSERT_FALSE(sonos_art_length_ok(404, SONOS_TILE_BYTES, SONOS_TILE_BYTES));
  TEST_ASSERT_FALSE(sonos_art_length_ok(0,   SONOS_TILE_BYTES, SONOS_TILE_BYTES));
}

static void test_length_ok_rejects_wrong_content_length(void) {
  TEST_ASSERT_FALSE(sonos_art_length_ok(200, SONOS_TILE_BYTES - 1, SONOS_TILE_BYTES));
  TEST_ASSERT_FALSE(sonos_art_length_ok(200, SONOS_TILE_BYTES + 1, SONOS_TILE_BYTES));
  TEST_ASSERT_FALSE(sonos_art_length_ok(200, -1, SONOS_TILE_BYTES));   // missing/absent header
}

static void test_length_ok_rejects_short_read(void) {
  // A Content-Length that merely UNDER-reports the true received count must still be rejected -- a
  // naive `received >= content_length` check would wave this through.
  TEST_ASSERT_FALSE(sonos_art_length_ok(200, SONOS_TILE_BYTES, SONOS_TILE_BYTES - 1));
  TEST_ASSERT_FALSE(sonos_art_length_ok(200, SONOS_TILE_BYTES, 0));
}

static void test_length_ok_accepts_only_all_three(void) {
  TEST_ASSERT_TRUE(sonos_art_length_ok(200, SONOS_TILE_BYTES, SONOS_TILE_BYTES));
}

// ============================================================================
// Layer 1: sonos_art_job_supersedes (design §4.4 "latest-wins")
// ============================================================================

static void test_job_supersedes_when_nothing_pending(void) {
  TEST_ASSERT_TRUE(sonos_art_job_supersedes(0, false, 1));
}

static void test_job_supersedes_true_for_a_different_gen(void) {
  TEST_ASSERT_TRUE(sonos_art_job_supersedes(5, true, 6));
}

static void test_job_supersedes_false_for_an_identical_repost(void) {
  // A duplicate S1 for the SAME gen (e.g. a BLE retransmit) must not restart an in-flight download.
  TEST_ASSERT_FALSE(sonos_art_job_supersedes(5, true, 5));
}

// ============================================================================
// Layer 1: sonos_art_err_for (design §2.3's frozen vocabulary; "size"/"no_wifi" never round-trip here)
// ============================================================================

static void test_err_for_maps_no_route_to_conn_refused(void) {
  TEST_ASSERT_EQUAL_STRING("conn_refused", sonos_art_err_for(ERR_NO_ROUTE));
}

static void test_err_for_maps_timeout_to_timeout(void) {
  TEST_ASSERT_EQUAL_STRING("timeout", sonos_art_err_for(ERR_TIMEOUT));
}

static void test_err_for_maps_http_to_http(void) {
  TEST_ASSERT_EQUAL_STRING("http", sonos_art_err_for(ERR_HTTP));
}

static void test_err_for_timeout_and_conn_refused_are_distinct(void) {
  // They must never collapse onto the same string -- they are precisely what a later workstream's
  // Local Network row distinguishes (design §2.3).
  TEST_ASSERT_TRUE(strcmp(sonos_art_err_for(ERR_TIMEOUT), sonos_art_err_for(ERR_NO_ROUTE)) != 0);
}

static void test_err_for_falls_back_to_net_for_unreachable_values(void) {
  TEST_ASSERT_EQUAL_STRING("net", sonos_art_err_for(ERR_RATE_LIMITED));
  TEST_ASSERT_EQUAL_STRING("net", sonos_art_err_for(ERR_PARSE));
}

// ============================================================================
// Layer 2: tile buffers (native-visible allocator/accessor -- plan §5 layer 2)
// ============================================================================

static void test_alloc_yields_two_distinct_non_null_buffers(void) {
  TEST_ASSERT_TRUE(sonos_art_alloc());
  uint8_t* a = sonos_art_buf(0);
  uint8_t* b = sonos_art_buf(1);
  TEST_ASSERT_NOT_NULL(a);
  TEST_ASSERT_NOT_NULL(b);
  TEST_ASSERT_TRUE(a != b);
}

static void test_alloc_is_idempotent(void) {
  TEST_ASSERT_TRUE(sonos_art_alloc());
  uint8_t* a0 = sonos_art_buf(0);
  uint8_t* b0 = sonos_art_buf(1);
  TEST_ASSERT_TRUE(sonos_art_alloc());   // second call: cheap no-op success, same buffers
  TEST_ASSERT_EQUAL_PTR(a0, sonos_art_buf(0));
  TEST_ASSERT_EQUAL_PTR(b0, sonos_art_buf(1));
}

static void test_buf_out_of_range_is_null(void) {
  sonos_art_alloc();
  TEST_ASSERT_NULL(sonos_art_buf(2));
}

// ============================================================================
// Layer 2: the race itself. A small sub-region of the real (80,000 B) allocated tiles stands in for
// "the tile" so a few-thousand-iteration loop runs fast; the protocol is size-independent (plan §5).
// ============================================================================

#define STAMP_BYTES 4096

struct RaceCtx {
  std::atomic<bool> writer_done{false};
  std::atomic<int>  torn{0};
  int               target;
  bool              obey_gate;   // true = the correct protocol; false = the deliberately broken one
};

static void race_writer(RaceCtx* ctx) {
  auto last_publish = std::chrono::steady_clock::now();
  uint32_t gen = 0;
  int published = 0;
  while (published < ctx->target) {
    sonos_art_rec_t rec = ds_get_sonos_art();
    if (ctx->obey_gate) {
      uint32_t elapsed_ms = (uint32_t)std::chrono::duration_cast<std::chrono::milliseconds>(
          std::chrono::steady_clock::now() - last_publish).count();
      if (!sonos_art_may_write(rec.gen, rec.seen_gen, elapsed_ms, 3000)) {
        std::this_thread::yield();
        continue;
      }
    }
    gen++;
    uint8_t back = sonos_art_back_idx(rec.idx);
    uint8_t* buf = sonos_art_buf(back);
    // A single repeated generation stamp: a torn tile is literally "two stamps in one buffer".
    memset(buf, (uint8_t)(gen & 0xFF), STAMP_BYTES);
    ds_publish_sonos_art(gen, back);
    last_publish = std::chrono::steady_clock::now();
    published++;
  }
  ctx->writer_done = true;
}

static void race_reader(RaceCtx* ctx) {
  int drain = 0;
  while (!ctx->writer_done.load() || drain < 500) {
    if (ctx->writer_done.load()) drain++;
    sonos_art_rec_t rec = ds_get_sonos_art();
    if (sonos_art_should_repoint(rec.gen, rec.seen_gen)) {
      uint8_t* buf = sonos_art_buf(rec.idx);
      uint8_t first = buf[0];
      bool torn = false;
      for (size_t i = 1; i < STAMP_BYTES; i++) {
        if (buf[i] != first) { torn = true; break; }
        // Widen the read window deliberately every so often -- exactly like a real render pass that
        // takes measurably longer than a raw memcpy, this is what gives a buggy writer (the negative
        // run) a realistic chance to race ahead and overwrite mid-read on any host, including a
        // single-core CI runner where a bare tight loop might never actually interleave.
        if ((i & 0xFF) == 0) std::this_thread::yield();
      }
      if (torn) ctx->torn.fetch_add(1);
      ds_sonos_art_seen(rec.gen);
    }
  }
}

static void test_race_positive_zero_torn_reads_when_writer_obeys_the_gate(void) {
  TEST_ASSERT_TRUE(sonos_art_alloc());
  RaceCtx ctx;
  ctx.target = 300;
  ctx.obey_gate = true;
  std::thread w(race_writer, &ctx);
  std::thread r(race_reader, &ctx);
  w.join();
  r.join();
  printf("[test_sonos_art] positive run: %d publishes, %d torn reads (expect 0)\n", ctx.target, ctx.torn.load());
  TEST_ASSERT_EQUAL_INT(0, ctx.torn.load());
}

// The negative control: without sonos_art_may_write gating the writer, it can overwrite the buffer the
// reader is mid-read on. This is what proves the positive run's zero is not vacuous -- if this run also
// came back 0, the test would prove nothing (plan §5's explicit warning).
static void test_race_negative_torn_reads_when_writer_ignores_the_gate(void) {
  TEST_ASSERT_TRUE(sonos_art_alloc());
  RaceCtx ctx;
  ctx.target = 4000;
  ctx.obey_gate = false;
  std::thread w(race_writer, &ctx);
  std::thread r(race_reader, &ctx);
  w.join();
  r.join();
  printf("[test_sonos_art] negative run: %d publishes, %d torn reads (expect > 0)\n", ctx.target, ctx.torn.load());
  TEST_ASSERT_TRUE(ctx.torn.load() > 0);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_back_idx_swaps_and_never_equals_input);
  RUN_TEST(test_may_write_false_before_ack_or_timeout);
  RUN_TEST(test_may_write_true_at_exact_timeout_with_no_ack);
  RUN_TEST(test_may_write_true_instantly_once_acked_regardless_of_elapsed);
  RUN_TEST(test_should_repoint_true_even_when_gen_is_numerically_smaller);
  RUN_TEST(test_should_repoint_false_when_equal);
  RUN_TEST(test_length_ok_rejects_non_200_status);
  RUN_TEST(test_length_ok_rejects_wrong_content_length);
  RUN_TEST(test_length_ok_rejects_short_read);
  RUN_TEST(test_length_ok_accepts_only_all_three);
  RUN_TEST(test_job_supersedes_when_nothing_pending);
  RUN_TEST(test_job_supersedes_true_for_a_different_gen);
  RUN_TEST(test_job_supersedes_false_for_an_identical_repost);
  RUN_TEST(test_err_for_maps_no_route_to_conn_refused);
  RUN_TEST(test_err_for_maps_timeout_to_timeout);
  RUN_TEST(test_err_for_maps_http_to_http);
  RUN_TEST(test_err_for_timeout_and_conn_refused_are_distinct);
  RUN_TEST(test_err_for_falls_back_to_net_for_unreachable_values);
  RUN_TEST(test_alloc_yields_two_distinct_non_null_buffers);
  RUN_TEST(test_alloc_is_idempotent);
  RUN_TEST(test_buf_out_of_range_is_null);
  RUN_TEST(test_race_positive_zero_torn_reads_when_writer_obeys_the_gate);
  RUN_TEST(test_race_negative_torn_reads_when_writer_ignores_the_gate);
  return UNITY_END();
}
