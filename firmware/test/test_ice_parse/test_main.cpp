#include <unity.h>
#include <string.h>
#include "fetch/parse_ice.h"

void setUp(void) {} void tearDown(void) {}

// Verbatim capture from the live endpoint (2026-07-26):
// GET www.ice.com/marketdata/api/productguide/charting/contract-data?productId=21781&hubId=24559
// Public, unauthenticated -- nothing here is a secret.
static const char* LIVE =
  "[ {\n"
  "  \"marketId\" : 7588608,\n"
  "  \"marketStrip\" : \"Dec26\",\n"
  "  \"endDate\" : 1798693200000,\n"
  "  \"lastPrice\" : 2.4345,\n"
  "  \"volume\" : 601,\n"
  "  \"lastTime\" : \"07/24/2026 07:30 PM GMT\",\n"
  "  \"change\" : 0.1851851851851739\n"
  "}, {\n"
  "  \"marketId\" : 8021425,\n"
  "  \"marketStrip\" : \"Dec27\",\n"
  "  \"endDate\" : 1830229200000,\n"
  "  \"lastPrice\" : 2.4500,\n"
  "  \"volume\" : 5,\n"
  "  \"lastTime\" : \"07/24/2026 12:14 PM GMT\",\n"
  "  \"change\" : -0.6085192697768633\n"
  "} ]";

static void test_live_payload(void) {
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_ice(LIVE, strlen(LIVE), &r));
  TEST_ASSERT_EQUAL_UINT8(2, r.count);

  // Tolerance is 1e-6, not 1e-9: ArduinoJson stores numbers as float32 in this build, so 2.4345 comes
  // back as 2.43449998. That is ~1.2e-7 of slack at this magnitude -- three orders finer than the 4dp
  // the screen renders (D4 RIN quotes move in 0.0001 increments), so it is precision we do not need.
  TEST_ASSERT_EQUAL_STRING("Dec26", r.c[0].strip);
  TEST_ASSERT_DOUBLE_WITHIN(1e-6, 2.4345, r.c[0].last);
  TEST_ASSERT_DOUBLE_WITHIN(1e-6, 0.18518518, r.c[0].change_pct);
  TEST_ASSERT_EQUAL_UINT32(601, r.c[0].volume);
  TEST_ASSERT_EQUAL_STRING("07/24/2026 07:30 PM GMT", r.c[0].last_time);

  TEST_ASSERT_EQUAL_STRING("Dec27", r.c[1].strip);
  TEST_ASSERT_DOUBLE_WITHIN(1e-6, 2.45, r.c[1].last);
  TEST_ASSERT_TRUE(r.c[1].change_pct < 0.0);   // signed: drives the down colour/glyph
  TEST_ASSERT_EQUAL_UINT32(5, r.c[1].volume);
}

// The endpoint returns [] outside a listing window. That is "nothing listed", not a failure -- the
// screen should show placeholders, not an ERROR chip.
static void test_empty_array_is_not_an_error(void) {
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_ice("[]", 2, &r));
  TEST_ASSERT_EQUAL_UINT8(0, r.count);
}

static void test_malformed_and_wrong_root(void) {
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_ice("not json", 8, &r));
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_ice("", 0, &r));
  // An object root (e.g. an error envelope) must not be read as contracts.
  const char* obj = "{\"error\":\"nope\"}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_ice(obj, strlen(obj), &r));
}

// A never-traded contract quotes lastPrice 0; printing "0.0000" would read as a real quote.
static void test_zero_and_missing_price_rows_skipped(void) {
  const char* j = "[{\"marketStrip\":\"Dec26\",\"lastPrice\":0,\"change\":0},"
                  "{\"marketStrip\":\"Dec27\"},"
                  "{\"marketStrip\":\"Dec28\",\"lastPrice\":2.5,\"change\":1.0}]";
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_ice(j, strlen(j), &r));
  TEST_ASSERT_EQUAL_UINT8(1, r.count);
  TEST_ASSERT_EQUAL_STRING("Dec28", r.c[0].strip);
}

static void test_caps_at_max_contracts(void) {
  char j[512] = "[";
  for (int i = 0; i < ICE_CONTRACTS_MAX + 3; i++)
    strcat(j, i ? ",{\"marketStrip\":\"Dec26\",\"lastPrice\":2.1,\"change\":0.5}"
               :  "{\"marketStrip\":\"Dec26\",\"lastPrice\":2.1,\"change\":0.5}");
  strcat(j, "]");
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_ice(j, strlen(j), &r));
  TEST_ASSERT_EQUAL_UINT8(ICE_CONTRACTS_MAX, r.count);
}

// Over-length strings must truncate, never overrun (records.h fixed-capacity rule).
static void test_overlong_strings_truncate(void) {
  const char* j = "[{\"marketStrip\":\"DecemberTwentySix\",\"lastPrice\":2.1,\"change\":0,"
                  "\"lastTime\":\"07/24/2026 07:30 PM GMT AND THEN SOME MORE\"}]";
  ice_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_ice(j, strlen(j), &r));
  TEST_ASSERT_EQUAL_UINT8(1, r.count);
  TEST_ASSERT_EQUAL_UINT(ICE_STRIP_LEN - 1, strlen(r.c[0].strip));
  TEST_ASSERT_EQUAL_UINT(ICE_TIME_LEN - 1, strlen(r.c[0].last_time));
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_live_payload);
  RUN_TEST(test_empty_array_is_not_an_error);
  RUN_TEST(test_malformed_and_wrong_root);
  RUN_TEST(test_zero_and_missing_price_rows_skipped);
  RUN_TEST(test_caps_at_max_contracts);
  RUN_TEST(test_overlong_strings_truncate);
  return UNITY_END();
}
