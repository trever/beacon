#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/hub_proto.h"

void setUp(void) {}
void tearDown(void) {}

static const char* OK_FRAME =
  "{\"v\":1,\"pages\":{\"rev\":3,\"list\":["
  "{\"id\":\"home\"},{\"id\":\"chart\",\"opts\":{\"symbol\":\"sp500\"}},{\"id\":\"agents\"}]}}";

static void test_parses_ids_in_order(void) {
  uint32_t rev = 0; page_list_t l; const char* err = "unset";
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_pages(OK_FRAME, strlen(OK_FRAME), &rev, &l, &err));
  TEST_ASSERT_EQUAL_UINT32(3, rev);
  TEST_ASSERT_EQUAL_UINT8(3, l.count);
  TEST_ASSERT_EQUAL_STRING("home",   l.ids[0]);
  TEST_ASSERT_EQUAL_STRING("chart",  l.ids[1]);
  TEST_ASSERT_EQUAL_STRING("agents", l.ids[2]);
}

// `opts` is reserved for per-page settings: it must parse and be ignored, never reject the frame.
static void test_opts_are_ignored_not_rejected(void) {
  const char* f = "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[{\"id\":\"chart\",\"opts\":{\"any\":[1,2,{\"x\":null}]}}]}}";
  uint32_t rev = 0; page_list_t l; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_pages(f, strlen(f), &rev, &l, &err));
  TEST_ASSERT_EQUAL_UINT8(1, l.count);
}

// Unknown ids are the resolve step's business, not the parser's -- an older device must still parse a
// newer hub's list and then drop what it lacks.
static void test_unknown_ids_parse_fine(void) {
  const char* f = "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[{\"id\":\"sonos\"}]}}";
  uint32_t rev = 0; page_list_t l; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_pages(f, strlen(f), &rev, &l, &err));
  TEST_ASSERT_EQUAL_STRING("sonos", l.ids[0]);
}

static void test_rejects_malformed(void) {
  uint32_t rev = 0; page_list_t l; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages("nope", 4, &rev, &l, &err));
  TEST_ASSERT_EQUAL_STRING("malformed", err);

  const char* v2 = "{\"v\":2,\"pages\":{\"rev\":1,\"list\":[{\"id\":\"home\"}]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(v2, strlen(v2), &rev, &l, &err));

  const char* norev = "{\"v\":1,\"pages\":{\"list\":[{\"id\":\"home\"}]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(norev, strlen(norev), &rev, &l, &err));

  const char* empty = "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(empty, strlen(empty), &rev, &l, &err));

  const char* blankid = "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[{\"id\":\"\"}]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(blankid, strlen(blankid), &rev, &l, &err));

  // A ticker config frame is not a pages frame.
  const char* cfg = "{\"v\":1,\"config\":{\"rev\":1,\"part\":0,\"parts\":1,\"tickers\":[]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(cfg, strlen(cfg), &rev, &l, &err));
}

static void test_rejects_too_many_pages(void) {
  char f[512];
  int n = snprintf(f, sizeof(f), "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[");
  for (int i = 0; i < PAGES_MAX + 1; i++)
    n += snprintf(f + n, sizeof(f) - (size_t)n, "%s{\"id\":\"p%d\"}", i ? "," : "", i);
  snprintf(f + n, sizeof(f) - (size_t)n, "]}}");
  uint32_t rev = 0; page_list_t l; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_pages(f, strlen(f), &rev, &l, &err));
  TEST_ASSERT_EQUAL_STRING("too_many_pages", err);
}

static void test_builds_ack(void) {
  char buf[96];
  size_t n = hub_build_pages_ack(buf, sizeof(buf), 7, true, NULL, 4);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL('\n', buf[n - 1]);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"cmd\":\"pages_ack\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"rev\":7"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"count\":4"));

  n = hub_build_pages_ack(buf, sizeof(buf), 7, false, "too_many_pages", 0);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"ok\":false"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"err\":\"too_many_pages\""));
  TEST_ASSERT_NULL(strstr(buf, "\"count\""));   // no count on failure
  TEST_ASSERT_EQUAL_size_t(0, hub_build_pages_ack(buf, 4, 7, true, NULL, 1));   // overflow => 0
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_parses_ids_in_order);
  RUN_TEST(test_opts_are_ignored_not_rejected);
  RUN_TEST(test_unknown_ids_parse_fine);
  RUN_TEST(test_rejects_malformed);
  RUN_TEST(test_rejects_too_many_pages);
  RUN_TEST(test_builds_ack);
  return UNITY_END();
}
