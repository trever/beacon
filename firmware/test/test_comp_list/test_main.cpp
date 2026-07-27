#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/complications.h"
#include "core/comp_state.h"

void setUp(void) {}
void tearDown(void) {}

// ===== catalog / face table =====

static uint8_t catalog_size(const char* id) {
  for (uint8_t i = 0; i < COMP_CATALOG_N; i++)
    if (strcmp(COMP_CATALOG[i].id, id) == 0) return COMP_CATALOG[i].size;
  return 0;
}

static bool catalog_takes_arg(const char* id) {
  for (uint8_t i = 0; i < COMP_CATALOG_N; i++)
    if (strcmp(COMP_CATALOG[i].id, id) == 0) return COMP_CATALOG[i].takes_arg;
  return false;
}

// The catalog is the SINGLE home of size/takes_arg (plan §13 item 1). This pins it to design §4.2's
// exact table so a later edit here shows up as a failing test, not a silently reflowed Home.
static void test_catalog_matches_design_table(void) {
  TEST_ASSERT_EQUAL_UINT8(8, COMP_CATALOG_N);
  TEST_ASSERT_EQUAL_UINT8(2, catalog_size("clock"));    TEST_ASSERT_FALSE(catalog_takes_arg("clock"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("fin"));      TEST_ASSERT_TRUE(catalog_takes_arg("fin"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("ice"));      TEST_ASSERT_FALSE(catalog_takes_arg("ice"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("agents"));   TEST_ASSERT_FALSE(catalog_takes_arg("agents"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("usage"));    TEST_ASSERT_TRUE(catalog_takes_arg("usage"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("weather"));  TEST_ASSERT_FALSE(catalog_takes_arg("weather"));
  TEST_ASSERT_EQUAL_UINT8(1, catalog_size("sonos"));    TEST_ASSERT_FALSE(catalog_takes_arg("sonos"));
  TEST_ASSERT_EQUAL_UINT8(2, catalog_size("chart"));    TEST_ASSERT_TRUE(catalog_takes_arg("chart"));
}

static void test_face_table_has_exactly_one_home(void) {
  TEST_ASSERT_EQUAL_UINT8(1, COMP_FACES_N);
  TEST_ASSERT_EQUAL_STRING("home", COMP_FACES[0].id);
  TEST_ASSERT_EQUAL_STRING("c_home", COMP_FACES[0].nvs_key);
  TEST_ASSERT_TRUE(strlen(COMP_FACES[0].nvs_key) <= 15);   // NVS key limit
  TEST_ASSERT_EQUAL_STRING("clock,fin.sp500,ice,agents", COMP_FACES[0].default_slots);
  TEST_ASSERT_EQUAL_UINT8(COMP_SLOTS_MAX, COMP_FACES[0].slots);
}

// ===== comp_entry_split / comp_entry_valid =====

static void test_entry_split_with_and_without_arg(void) {
  char id[COMP_ID_LEN], arg[COMP_ARG_LEN];
  TEST_ASSERT_TRUE(comp_entry_split("fin.sp500", id, sizeof(id), arg, sizeof(arg)));
  TEST_ASSERT_EQUAL_STRING("fin", id);
  TEST_ASSERT_EQUAL_STRING("sp500", arg);

  TEST_ASSERT_TRUE(comp_entry_split("clock", id, sizeof(id), arg, sizeof(arg)));
  TEST_ASSERT_EQUAL_STRING("clock", id);
  TEST_ASSERT_EQUAL_STRING("", arg);
}

static void test_entry_split_rejects_malformed(void) {
  char id[COMP_ID_LEN], arg[COMP_ARG_LEN];
  TEST_ASSERT_FALSE(comp_entry_split("", id, sizeof(id), arg, sizeof(arg)));
  TEST_ASSERT_FALSE(comp_entry_split(NULL, id, sizeof(id), arg, sizeof(arg)));
  TEST_ASSERT_FALSE(comp_entry_split("fin.", id, sizeof(id), arg, sizeof(arg)));      // trailing dot
  TEST_ASSERT_FALSE(comp_entry_split(".sp500", id, sizeof(id), arg, sizeof(arg)));    // empty id
  TEST_ASSERT_FALSE(comp_entry_split("fin.sp.500", id, sizeof(id), arg, sizeof(arg))); // second dot
  char tinyid[4];
  TEST_ASSERT_FALSE(comp_entry_split("clock", tinyid, sizeof(tinyid), arg, sizeof(arg)));  // id too long
}

static void test_entry_valid_charset_and_length_bounds(void) {
  TEST_ASSERT_TRUE(comp_entry_valid("fin", "sp500"));
  TEST_ASSERT_TRUE(comp_entry_valid("clock", ""));            // no arg is always fine
  TEST_ASSERT_TRUE(comp_entry_valid("abcdefghijk", NULL));     // exactly 11 chars, NULL arg tolerated
  TEST_ASSERT_FALSE(comp_entry_valid("abcdefghijkl", ""));     // 12 chars: over COMP_ID_LEN-1
  TEST_ASSERT_FALSE(comp_entry_valid("", ""));                 // empty id
  TEST_ASSERT_FALSE(comp_entry_valid("FIN", "sp500"));         // uppercase not in [a-z0-9_-]
  TEST_ASSERT_FALSE(comp_entry_valid("fin", "sp 500"));        // space in arg
  TEST_ASSERT_FALSE(comp_entry_valid("fin", "sp.500"));        // dot in arg
  TEST_ASSERT_TRUE(comp_entry_valid("fin", "123456789012345")); // exactly 15 chars
  TEST_ASSERT_FALSE(comp_entry_valid("fin", "1234567890123456")); // 16 chars: over COMP_ARG_LEN-1
  TEST_ASSERT_TRUE(comp_entry_valid("under_score", "ok-1"));   // '_' and '-' are both in the alphabet
}

// ===== serialize / deserialize =====

static comp_list_t of(const char* csv) { comp_list_t l; comp_list_deserialize(csv, &l); return l; }

static void assert_ids_args(const comp_list_t* l, const char* csv) {
  comp_list_t want = of(csv);
  TEST_ASSERT_EQUAL_UINT8(want.count, l->count);
  for (uint8_t i = 0; i < want.count; i++) {
    TEST_ASSERT_EQUAL_STRING(want.ids[i],  l->ids[i]);
    TEST_ASSERT_EQUAL_STRING(want.args[i], l->args[i]);
  }
}

static void test_serialize_deserialize_roundtrip(void) {
  comp_list_t l = of("clock,fin.sp500,ice,agents");
  TEST_ASSERT_EQUAL_UINT8(4, l.count);
  char buf[128];
  size_t n = comp_list_serialize(&l, buf, sizeof(buf));
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL_STRING("clock,fin.sp500,ice,agents", buf);

  comp_list_t back = of(buf);
  TEST_ASSERT_TRUE(comp_list_equal(&l, &back));
}

// A corrupt NVS blob must degrade to something resolvable, never crash or overrun.
static void test_deserialize_tolerates_junk(void) {
  comp_list_t l = of(",,clock,,,fin.sp500,");
  assert_ids_args(&l, "clock,fin.sp500");
  comp_list_t e = of("");
  TEST_ASSERT_EQUAL_UINT8(0, e.count);
  comp_list_t n; comp_list_deserialize(NULL, &n);
  TEST_ASSERT_EQUAL_UINT8(0, n.count);
}

// A token that cannot split (trailing dot, oversize) is dropped rather than corrupting the whole list.
static void test_deserialize_drops_unsplittable_tokens_but_keeps_the_rest(void) {
  comp_list_t l = of("fin.sp500,BAD.,ice,agents");
  TEST_ASSERT_EQUAL_UINT8(3, l.count);
  TEST_ASSERT_EQUAL_STRING("fin",    l.ids[0]);
  TEST_ASSERT_EQUAL_STRING("sp500",  l.args[0]);
  TEST_ASSERT_EQUAL_STRING("ice",    l.ids[1]);
  TEST_ASSERT_EQUAL_STRING("agents", l.ids[2]);
}

// ===== comp_list_equal =====

static void test_equal_detects_order_and_arg_changes(void) {
  comp_list_t a = of("clock,fin.sp500");
  comp_list_t b = of("clock,fin.sp500");
  TEST_ASSERT_TRUE(comp_list_equal(&a, &b));

  comp_list_t c = of("fin.sp500,clock");   // order differs
  TEST_ASSERT_FALSE(comp_list_equal(&a, &c));

  comp_list_t d = of("clock,fin.nasdaq");  // arg differs
  TEST_ASSERT_FALSE(comp_list_equal(&a, &d));

  TEST_ASSERT_TRUE(comp_list_equal(&a, &a));
  TEST_ASSERT_TRUE(comp_list_equal(NULL, NULL));
  TEST_ASSERT_FALSE(comp_list_equal(&a, NULL));
}

// ===== resolve =====

// A Phase-1-shaped known set: every catalog id except "chart" (its renderer is Phase 2 -- comp_find
// would return NULL for it on real firmware, so it is deliberately absent from `known` here too).
static const char* KNOWN[] = {"clock", "fin", "ice", "agents", "usage", "weather", "sonos"};
static const uint8_t KNOWN_N = 7;

static uint8_t resolve_known(const comp_list_t* requested, bool explicit_empty,
                             const comp_list_t* fallback, comp_list_t* out) {
  uint8_t sizes[KNOWN_N];
  for (uint8_t i = 0; i < KNOWN_N; i++) sizes[i] = catalog_size(KNOWN[i]);
  return comp_list_resolve(requested, KNOWN, sizes, KNOWN_N, COMP_SLOTS_MAX, explicit_empty, fallback, out);
}

static void test_resolve_drops_unknown_id_and_compacts(void) {
  comp_list_t want = of("chart.sp500,fin.sp500,ice"), fb = of("clock"), out;
  resolve_known(&want, false, &fb, &out);
  assert_ids_args(&out, "fin.sp500,ice");
}

static void test_resolve_collapses_duplicate_ids_first_arg_wins(void) {
  comp_list_t want = of("fin.sp500,ice,fin.nasdaq"), fb = of("clock"), out;
  resolve_known(&want, false, &fb, &out);
  assert_ids_args(&out, "fin.sp500,ice");   // second "fin" dropped even though its arg differs
}

static bool out_contains(const comp_list_t* l, const char* id) {
  for (uint8_t i = 0; i < l->count; i++) if (strcmp(l->ids[i], id) == 0) return true;
  return false;
}

// A 2-slot entry that does not fit the remaining unit is dropped, but the walk continues: a LATER
// 1-slot entry still places in the unit the 2-slot one could not use. `comp_list_t` structurally holds
// at most COMP_SLOTS_MAX (6) raw entries, so this needs TWO distinct 2-slot ids to set up "5 units used,
// 1 remaining" without exhausting the raw-entry budget before the drop can even be tried -- a local
// known-set (clock AND chart both 2-slot) rather than the shared Phase-1-shaped KNOWN[] above.
static void test_resolve_drops_oversized_entry_but_places_later_smaller_one(void) {
  static const char* known[] = {"clock", "chart", "fin", "ice", "agents", "usage"};
  static const uint8_t sizes[] = {2, 2, 1, 1, 1, 1};
  // chart(2) + fin(1) + ice(1) + agents(1) = 5 units used, 1 remains. "clock" (2 units) then cannot fit
  // and is dropped; "usage" (1 unit) right after it still places in the one remaining unit.
  comp_list_t want = of("chart,fin,ice,agents,clock,usage"), fb = of("clock"), out;
  comp_list_resolve(&want, known, sizes, 6, COMP_SLOTS_MAX, false, &fb, &out);
  assert_ids_args(&out, "chart,fin,ice,agents,usage");
  TEST_ASSERT_FALSE(out_contains(&out, "clock"));
}

// Over the total capacity, the TAIL truncates: nothing after the point capacity runs out can place.
static void test_resolve_truncates_over_capacity(void) {
  // clock(2) + fin+ice+agents+usage = 2+1+1+1+1 = 6 (full). weather/sonos truncate off the tail.
  comp_list_t want = of("clock,fin,ice,agents,usage,weather,sonos"), fb = of("clock"), out;
  uint8_t n = resolve_known(&want, false, &fb, &out);
  TEST_ASSERT_EQUAL_UINT8(5, n);
  assert_ids_args(&out, "clock,fin,ice,agents,usage");
  TEST_ASSERT_FALSE(out_contains(&out, "weather"));
  TEST_ASSERT_FALSE(out_contains(&out, "sonos"));
}

// rule 5: an explicitly empty request is honoured, never falls back to a non-blank default.
static void test_resolve_honours_explicit_empty(void) {
  comp_list_t empty; memset(&empty, 0, sizeof(empty));
  comp_list_t fb = of("clock,fin.sp500,ice,agents"), out;
  uint8_t n = resolve_known(&empty, /*explicit_empty=*/true, &fb, &out);
  TEST_ASSERT_EQUAL_UINT8(0, n);
  TEST_ASSERT_EQUAL_UINT8(0, out.count);
}

// A non-empty request that resolves to nothing usable (everything named is unknown) falls back --
// this is exactly what distinguishes it from the explicit-empty case above, hence the explicit flag.
static void test_resolve_falls_back_when_everything_unknown(void) {
  comp_list_t want = of("nope1,nope2"), fb = of("clock,fin.sp500,ice,agents"), out;
  uint8_t n = resolve_known(&want, /*explicit_empty=*/false, &fb, &out);
  TEST_ASSERT_EQUAL_UINT8(4, n);
  assert_ids_args(&out, "clock,fin.sp500,ice,agents");
}

// A stale fallback must not smuggle in an id this build no longer carries.
static void test_resolve_filters_the_fallback_too(void) {
  comp_list_t empty; memset(&empty, 0, sizeof(empty));
  comp_list_t fb = of("chart.sp500,clock"), out;   // "chart" is not in KNOWN (Phase 2)
  resolve_known(&empty, false, &fb, &out);
  assert_ids_args(&out, "clock");
}

// An entry with a character outside [a-z0-9_-] is dropped, same as an unknown id.
static void test_resolve_drops_out_of_alphabet_entry(void) {
  comp_list_t want; memset(&want, 0, sizeof(want));
  snprintf(want.ids[0], COMP_ID_LEN, "FIN");    // uppercase: fails comp_entry_valid
  snprintf(want.ids[1], COMP_ID_LEN, "ice");
  snprintf(want.ids[2], COMP_ID_LEN, "agents");
  want.count = 3;
  comp_list_t fb = of("clock"), out;
  resolve_known(&want, false, &fb, &out);
  assert_ids_args(&out, "ice,agents");
}

// The default assignment (design §7): clock(2) at slots 1-2, fin.sp500 at 3, ice at 4, agents at 5,
// slot 6 free. Verified here by walking placement order + catalog size, independent of any LVGL anchor
// math (test_comp_geom, WS-1, covers the pixel side).
static void test_default_string_resolves_to_expected_slots(void) {
  comp_list_t empty; memset(&empty, 0, sizeof(empty));
  comp_list_t fb = of(COMP_FACES[0].default_slots), out;
  uint8_t n = resolve_known(&empty, false, &fb, &out);
  TEST_ASSERT_EQUAL_UINT8(4, n);
  assert_ids_args(&out, "clock,fin.sp500,ice,agents");

  uint8_t slot = 1, used = 0;
  uint8_t starts[4];
  for (uint8_t i = 0; i < out.count; i++) {
    starts[i] = slot;
    uint8_t size = catalog_size(out.ids[i]);
    slot = (uint8_t)(slot + size);
    used = (uint8_t)(used + size);
  }
  TEST_ASSERT_EQUAL_UINT8(1, starts[0]);   // clock: slots 1-2
  TEST_ASSERT_EQUAL_UINT8(3, starts[1]);   // fin.sp500: slot 3
  TEST_ASSERT_EQUAL_UINT8(4, starts[2]);   // ice: slot 4
  TEST_ASSERT_EQUAL_UINT8(5, starts[3]);   // agents: slot 5
  TEST_ASSERT_EQUAL_UINT8(5, used);        // slot 6 free
}

static void test_resolve_handles_null_requested(void) {
  comp_list_t fb = of("clock,fin.sp500,ice,agents"), out;
  TEST_ASSERT_EQUAL_UINT8(4, resolve_known(NULL, false, &fb, &out));
}

// ===== comp_state =====

static void test_state_active_roundtrips_by_value(void) {
  comp_list_t l = of("clock,fin.sp500");
  comp_state_set_active(&l);
  comp_list_t out; memset(&out, 0xAA, sizeof(out));
  TEST_ASSERT_TRUE(comp_state_active(&out));
  TEST_ASSERT_TRUE(comp_list_equal(&l, &out));
}

static void test_state_pending_set_then_take_clears(void) {
  comp_list_t l = of("ice,agents");
  comp_state_set_pending(&l);
  comp_list_t out; memset(&out, 0, sizeof(out));
  TEST_ASSERT_TRUE(comp_state_take_pending(&out));
  TEST_ASSERT_TRUE(comp_list_equal(&l, &out));
  // Second take with nothing newly pending: false, and *out must be left untouched.
  comp_list_t sentinel = of("weather");
  comp_list_t out2 = sentinel;
  TEST_ASSERT_FALSE(comp_state_take_pending(&out2));
  TEST_ASSERT_TRUE(comp_list_equal(&sentinel, &out2));
}

static void test_comp_arg_finds_value_or_reports_absent(void) {
  comp_list_t l = of("fin.sp500,ice,usage.claude");
  comp_state_set_active(&l);

  char v[COMP_ARG_LEN];
  TEST_ASSERT_TRUE(comp_arg("fin", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("sp500", v);
  TEST_ASSERT_TRUE(comp_arg("usage", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("claude", v);

  // Placed but carries no arg: false, and `out` is emptied.
  TEST_ASSERT_FALSE(comp_arg("ice", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("", v);

  // Not placed at all: false.
  TEST_ASSERT_FALSE(comp_arg("weather", v, sizeof(v)));
  TEST_ASSERT_EQUAL_STRING("", v);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_catalog_matches_design_table);
  RUN_TEST(test_face_table_has_exactly_one_home);
  RUN_TEST(test_entry_split_with_and_without_arg);
  RUN_TEST(test_entry_split_rejects_malformed);
  RUN_TEST(test_entry_valid_charset_and_length_bounds);
  RUN_TEST(test_serialize_deserialize_roundtrip);
  RUN_TEST(test_deserialize_tolerates_junk);
  RUN_TEST(test_deserialize_drops_unsplittable_tokens_but_keeps_the_rest);
  RUN_TEST(test_equal_detects_order_and_arg_changes);
  RUN_TEST(test_resolve_drops_unknown_id_and_compacts);
  RUN_TEST(test_resolve_collapses_duplicate_ids_first_arg_wins);
  RUN_TEST(test_resolve_drops_oversized_entry_but_places_later_smaller_one);
  RUN_TEST(test_resolve_truncates_over_capacity);
  RUN_TEST(test_resolve_honours_explicit_empty);
  RUN_TEST(test_resolve_falls_back_when_everything_unknown);
  RUN_TEST(test_resolve_filters_the_fallback_too);
  RUN_TEST(test_resolve_drops_out_of_alphabet_entry);
  RUN_TEST(test_default_string_resolves_to_expected_slots);
  RUN_TEST(test_resolve_handles_null_requested);
  RUN_TEST(test_state_active_roundtrips_by_value);
  RUN_TEST(test_state_pending_set_then_take_clears);
  RUN_TEST(test_comp_arg_finds_value_or_reports_absent);
  return UNITY_END();
}
