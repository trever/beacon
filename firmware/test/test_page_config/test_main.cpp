#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/page_config.h"

void setUp(void) {}
void tearDown(void) {}

static const char* KNOWN[] = {"home", "markets", "chart", "ice", "agents", "settings"};
static const uint8_t KNOWN_N = 6;

static page_list_t of(const char* csv) { page_list_t l; page_list_deserialize(csv, &l); return l; }

static void assert_ids(const page_list_t* l, const char* csv) {
  char buf[PAGES_MAX * PAGE_ID_LEN];
  page_list_serialize(l, buf, sizeof(buf));
  TEST_ASSERT_EQUAL_STRING(csv, buf);
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
  return UNITY_END();
}
