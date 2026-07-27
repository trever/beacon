#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/page_config.h"

void setUp(void) {}
void tearDown(void) {}

static const char* KNOWN[] = {"home", "markets", "chart", "ice", "agents", "settings"};
static const uint8_t KNOWN_N = 6;

static page_list_t of(const char* csv) { page_list_t l; page_list_deserialize(csv, &l); return l; }

// Compares the ids directly rather than via page_list_serialize: the serialized form has its own
// round-trip test, and these cases are about resolve's rules, not the storage format.
static void assert_ids(const page_list_t* l, const char* csv) {
  page_list_t want; page_list_deserialize(csv, &want);
  TEST_ASSERT_EQUAL_UINT8(want.count, l->count);
  for (uint8_t i = 0; i < want.count; i++) TEST_ASSERT_EQUAL_STRING(want.ids[i], l->ids[i]);
}

// ===== serialize / deserialize =====

static void test_roundtrip(void) {
  page_list_t l = of("home,chart,agents,settings");
  TEST_ASSERT_EQUAL_UINT8(4, l.count);
  assert_ids(&l, "home,chart,agents,settings");
}

// A corrupt NVS blob must degrade to something resolvable, never crash or overrun.
static void test_deserialize_tolerates_junk(void) {
  page_list_t l = of(",,home,,,chart,");
  assert_ids(&l, "home,chart");
  page_list_t e = of("");
  TEST_ASSERT_EQUAL_UINT8(0, e.count);
  page_list_t n; page_list_deserialize(NULL, &n);
  TEST_ASSERT_EQUAL_UINT8(0, n.count);
}

static void test_deserialize_truncates_overlong_id(void) {
  page_list_t l = of("averyveryverylongpageid,home");
  TEST_ASSERT_EQUAL_UINT8(2, l.count);
  TEST_ASSERT_EQUAL_UINT(PAGE_ID_LEN - 1, strlen(l.ids[0]));
}

static void test_add_rejects_duplicates_and_overflow(void) {
  page_list_t l; memset(&l, 0, sizeof(l));
  TEST_ASSERT_TRUE(page_list_add(&l, "home"));
  TEST_ASSERT_FALSE(page_list_add(&l, "home"));       // duplicate
  for (int i = 1; i < PAGES_MAX; i++) {
    char id[PAGE_ID_LEN]; snprintf(id, sizeof(id), "p%d", i);
    TEST_ASSERT_TRUE(page_list_add(&l, id));
  }
  TEST_ASSERT_EQUAL_UINT8(PAGES_MAX, l.count);
  TEST_ASSERT_FALSE(page_list_add(&l, "overflow"));   // full
}

// ===== resolve =====

static void test_resolve_keeps_requested_order(void) {
  page_list_t want = of("agents,ice,home,settings"), fb = of("home,settings"), out;
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "agents,ice,home,settings");
}

// A newer hub may name a page this firmware does not carry. Dropping it keeps the device usable;
// rejecting the whole list would strand it on an old page set.
static void test_resolve_drops_unknown_ids(void) {
  page_list_t want = of("home,sonos,chart,settings"), fb = of("home,settings"), out;
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,chart,settings");
}

static void test_resolve_collapses_duplicates(void) {
  page_list_t want = of("home,home,chart,home"), fb = of("home,settings"), out;
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,chart,settings");
}

// The lockout guard: no configuration may leave the device unable to reach its own settings.
static void test_resolve_always_appends_settings(void) {
  page_list_t want = of("home,chart"), fb = of("home,settings"), out;
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,chart,settings");
}

// ...even when the list is already full: losing the least-prominent page beats losing settings.
static void test_resolve_evicts_to_fit_settings(void) {
  const char* k[] = {"a","b","c","d","e","f","g","h","settings"};
  page_list_t want = of("a,b,c,d,e,f,g,h"), fb = of("a"), out;
  uint8_t n = page_list_resolve(&want, k, 9, "settings", &fb, &out);
  TEST_ASSERT_EQUAL_UINT8(PAGES_MAX, n);
  TEST_ASSERT_TRUE(page_list_contains(&out, "settings"));
  TEST_ASSERT_FALSE(page_list_contains(&out, "h"));   // last entry evicted to make room
}

// Empty or entirely-unknown requests fall back rather than rendering a blank carousel.
static void test_resolve_falls_back_when_nothing_usable(void) {
  page_list_t fb = of("home,settings"), out;
  page_list_t empty; memset(&empty, 0, sizeof(empty));
  page_list_resolve(&empty, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,settings");

  page_list_t junk = of("nope,alsonope");
  page_list_resolve(&junk, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,settings");
}

// A stale fallback must not smuggle in an id this build no longer carries.
static void test_resolve_filters_the_fallback_too(void) {
  page_list_t fb = of("usage,home"), out;      // "usage" was removed from this firmware
  page_list_t empty; memset(&empty, 0, sizeof(empty));
  page_list_resolve(&empty, KNOWN, KNOWN_N, "settings", &fb, &out);
  assert_ids(&out, "home,settings");
}

static void test_resolve_handles_null_requested(void) {
  page_list_t fb = of("home,settings"), out;
  TEST_ASSERT_EQUAL_UINT8(2, page_list_resolve(NULL, KNOWN, KNOWN_N, "settings", &fb, &out));
}

// ===== per-page options =====

static void test_opts_get(void) {
  char v[32];
  TEST_ASSERT_TRUE(page_opts_get("sym:sp500;iv:15m", "sym", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("sp500", v);
  TEST_ASSERT_TRUE(page_opts_get("sym:sp500;iv:15m", "iv", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("15m", v);
  TEST_ASSERT_FALSE(page_opts_get("sym:sp500", "nope", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("", v);
  TEST_ASSERT_FALSE(page_opts_get("", "sym", v, sizeof(v)));
  TEST_ASSERT_FALSE(page_opts_get(NULL, "sym", v, sizeof(v)));
}

// A key that merely PREFIXES another must not match it, or "sym" would read "symbol"'s value.
static void test_opts_get_requires_exact_key(void) {
  char v[32];
  TEST_ASSERT_FALSE(page_opts_get("symbol:x", "sym", v, sizeof(v)));
  TEST_ASSERT_TRUE(page_opts_get("symbol:x", "symbol", v, sizeof(v)));
}

static void test_opts_get_truncates_into_small_buffer(void) {
  char v[4];
  TEST_ASSERT_TRUE(page_opts_get("sym:abcdefgh", "sym", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("abc", v);
}

// Record separators inside a value would split the stored blob; set_opts strips them.
static void test_set_opts_strips_record_separators(void) {
  page_list_t l = of("chart");
  page_list_set_opts(&l, "chart", "sym:a|b=c,d");
  TEST_ASSERT_EQUAL_STRING("sym:abcd", page_list_opts(&l, "chart"));
}

static void test_set_opts_ignores_unknown_page(void) {
  page_list_t l = of("chart");
  page_list_set_opts(&l, "ice", "x:1");
  TEST_ASSERT_EQUAL_STRING("", page_list_opts(&l, "ice"));
}

static void test_opts_survive_serialize_roundtrip(void) {
  page_list_t l = of("home,chart,settings");
  page_list_set_opts(&l, "chart", "sym:btc");
  char buf[PAGES_MAX * (PAGE_ID_LEN + PAGE_OPTS_LEN)];
  page_list_serialize(&l, buf, sizeof(buf));
  TEST_ASSERT_EQUAL_STRING("home|chart=sym:btc|settings", buf);

  page_list_t back; page_list_deserialize(buf, &back);
  TEST_ASSERT_EQUAL_UINT8(3, back.count);
  TEST_ASSERT_EQUAL_STRING("sym:btc", page_list_opts(&back, "chart"));
  TEST_ASSERT_EQUAL_STRING("", page_list_opts(&back, "home"));
}

// A blob written before options existed is comma-joined with no '|'. Reading it keeps the user's page
// set across the firmware update instead of silently resetting to the default.
static void test_deserialize_reads_legacy_comma_format(void) {
  page_list_t l = of("home,chart,agents,settings");
  TEST_ASSERT_EQUAL_UINT8(4, l.count);
  TEST_ASSERT_EQUAL_STRING("home", l.ids[0]);
  TEST_ASSERT_EQUAL_STRING("settings", l.ids[3]);
}

static void test_resolve_carries_opts(void) {
  page_list_t want = of("chart|home"), fb = of("home,settings"), out;
  page_list_set_opts(&want, "chart", "sym:eth");
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &out);
  TEST_ASSERT_EQUAL_STRING("sym:eth", page_list_opts(&out, "chart"));
  TEST_ASSERT_EQUAL_STRING("", page_list_opts(&out, "home"));
}

// ===== idempotence =====
//
// REGRESSION: the hub re-pushes the current page config on every reconnect. The device used to apply and
// restart unconditionally, so the restart reconnected, was re-pushed, and restarted again -- a boot loop
// that only stopped when the hub was killed. Applying an identical list must be a no-op.

static void test_equal_detects_identical_lists(void) {
  page_list_t a = of("home|chart=sym:btc|settings");
  page_list_t b = of("home|chart=sym:btc|settings");
  TEST_ASSERT_TRUE(page_list_equal(&a, &b));
}

static void test_equal_detects_order_change(void) {
  page_list_t a = of("home|chart|settings");
  page_list_t b = of("chart|home|settings");
  TEST_ASSERT_FALSE(page_list_equal(&a, &b));
}

// The instrument changing with the order untouched still has to reach the device.
static void test_equal_detects_option_change(void) {
  page_list_t a = of("chart=sym:sp500");
  page_list_t b = of("chart=sym:btc");
  TEST_ASSERT_FALSE(page_list_equal(&a, &b));
}

static void test_equal_detects_added_or_removed_page(void) {
  page_list_t a = of("home|settings");
  page_list_t b = of("home|chart|settings");
  TEST_ASSERT_FALSE(page_list_equal(&a, &b));
  TEST_ASSERT_TRUE(page_list_equal(&a, &a));
  TEST_ASSERT_FALSE(page_list_equal(&a, NULL));
  TEST_ASSERT_TRUE(page_list_equal(NULL, NULL));
}

// What the device actually does: resolve the pushed list, compare to what is running. A re-push of the
// running config must compare equal even though it went through resolve (which appends settings).
static void test_resolved_repush_equals_running(void) {
  page_list_t fb = of("home,settings"), first, second;
  page_list_t want = of("home|chart=sym:btc");
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &first);
  page_list_resolve(&want, KNOWN, KNOWN_N, "settings", &fb, &second);
  TEST_ASSERT_TRUE(page_list_equal(&first, &second));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_roundtrip);
  RUN_TEST(test_deserialize_tolerates_junk);
  RUN_TEST(test_deserialize_truncates_overlong_id);
  RUN_TEST(test_add_rejects_duplicates_and_overflow);
  RUN_TEST(test_resolve_keeps_requested_order);
  RUN_TEST(test_resolve_drops_unknown_ids);
  RUN_TEST(test_resolve_collapses_duplicates);
  RUN_TEST(test_resolve_always_appends_settings);
  RUN_TEST(test_resolve_evicts_to_fit_settings);
  RUN_TEST(test_resolve_falls_back_when_nothing_usable);
  RUN_TEST(test_resolve_filters_the_fallback_too);
  RUN_TEST(test_resolve_handles_null_requested);
  RUN_TEST(test_opts_get);
  RUN_TEST(test_opts_get_requires_exact_key);
  RUN_TEST(test_opts_get_truncates_into_small_buffer);
  RUN_TEST(test_set_opts_strips_record_separators);
  RUN_TEST(test_set_opts_ignores_unknown_page);
  RUN_TEST(test_opts_survive_serialize_roundtrip);
  RUN_TEST(test_deserialize_reads_legacy_comma_format);
  RUN_TEST(test_resolve_carries_opts);
  RUN_TEST(test_equal_detects_identical_lists);
  RUN_TEST(test_equal_detects_order_change);
  RUN_TEST(test_equal_detects_option_change);
  RUN_TEST(test_equal_detects_added_or_removed_page);
  RUN_TEST(test_resolved_repush_equals_running);
  return UNITY_END();
}