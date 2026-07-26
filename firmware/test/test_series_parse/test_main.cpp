#include <unity.h>
#include <string.h>
#include "fetch/parse_series.h"

void setUp(void) {} void tearDown(void) {}

// Shaped from the live Yahoo chart response (range=1d&interval=15m, %5EGSPC, 2026-07-26).
static const char* OK =
  "{\"chart\":{\"result\":[{"
  "\"meta\":{\"regularMarketPrice\":7411.98,\"previousClose\":7408.3,\"chartPreviousClose\":7400.0},"
  "\"timestamp\":[1,2,3,4],"
  "\"indicators\":{\"quote\":[{\"close\":[7405.5,7418.1,null,7412.0],"
  "\"volume\":[1,2,3,4],\"open\":[1,2,3,4]}]}"
  "}],\"error\":null}}";

static void test_live_shape(void) {
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_series(OK, strlen(OK), &r));
  // The null bucket is SKIPPED, not zero-filled: a 0.0 would collapse the y-range.
  TEST_ASSERT_EQUAL_UINT16(3, r.count);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 7405.5f, r.v[0]);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 7418.1f, r.v[1]);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 7412.0f, r.v[2]);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 7405.5f, r.lo);
  TEST_ASSERT_FLOAT_WITHIN(0.01f, 7418.1f, r.hi);
  // meta.regularMarketPrice wins over the last bucket, which can lag it by minutes.
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 7411.98, r.last);
  // previousClose is preferred over chartPreviousClose when both are present.
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 7408.3, r.prev_close);
}

static void test_prev_close_falls_back(void) {
  const char* j = "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":100.0,"
                  "\"chartPreviousClose\":98.0},"
                  "\"indicators\":{\"quote\":[{\"close\":[99.0,100.0]}]}}]}}";
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_series(j, strlen(j), &r));
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 98.0, r.prev_close);
}

// No meta price at all: fall back to the newest bucket rather than reporting 0.
static void test_last_falls_back_to_final_bucket(void) {
  const char* j = "{\"chart\":{\"result\":[{\"meta\":{},"
                  "\"indicators\":{\"quote\":[{\"close\":[10.0,20.0,30.0]}]}}]}}";
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_series(j, strlen(j), &r));
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 30.0, r.last);
  TEST_ASSERT_DOUBLE_WITHIN(0.01, 30.0, r.prev_close);   // no basis => zero change, not a fake one
}

static void test_all_null_closes_is_parse_error(void) {
  const char* j = "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.0},"
                  "\"indicators\":{\"quote\":[{\"close\":[null,null]}]}}]}}";
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_series(j, strlen(j), &r));
}

static void test_malformed_and_missing_branches(void) {
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_series("not json", 8, &r));
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_series("", 0, &r));
  const char* noclose = "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.0}}]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_series(noclose, strlen(noclose), &r));
  // Yahoo's error envelope has result:null.
  const char* errenv = "{\"chart\":{\"result\":null,\"error\":{\"code\":\"Not Found\"}}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, parse_series(errenv, strlen(errenv), &r));
}

// A response longer than SERIES_MAX must not overrun v[].
static void test_caps_at_series_max(void) {
  char j[4096]; strcpy(j, "{\"chart\":{\"result\":[{\"meta\":{\"regularMarketPrice\":1.0},"
                          "\"indicators\":{\"quote\":[{\"close\":[");
  for (int i = 0; i < SERIES_MAX + 20; i++) strcat(j, i ? ",1.5" : "1.5");
  strcat(j, "]}]}}]}}");
  series_rec_t r; memset(&r, 0, sizeof(r));
  TEST_ASSERT_EQUAL_INT(ERR_NONE, parse_series(j, strlen(j), &r));
  TEST_ASSERT_EQUAL_UINT16(SERIES_MAX, r.count);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_live_shape);
  RUN_TEST(test_prev_close_falls_back);
  RUN_TEST(test_last_falls_back_to_final_bucket);
  RUN_TEST(test_all_null_closes_is_parse_error);
  RUN_TEST(test_malformed_and_missing_branches);
  RUN_TEST(test_caps_at_series_max);
  return UNITY_END();
}
