#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/hub_proto.h"

void setUp(void) {}
void tearDown(void) {}

// Fill a buddy record with `n` sessions s1..sn, no detail.
static void seed(buddy_rec_t* b, uint8_t n) {
  memset(b, 0, sizeof(*b));
  b->session_count = n;
  for (uint8_t i = 0; i < n; i++) {
    snprintf(b->sessions[i].id, BUDDY_SID_LEN, "s%u", (unsigned)(i + 1));
    snprintf(b->sessions[i].label, BUDDY_LABEL_LEN, "proj%u", (unsigned)(i + 1));
  }
}

static const char* SD_TWO =
  "{\"v\":1,\"sdetail\":["
  "{\"id\":\"s1\",\"project\":\"beacon\",\"title\":\"graph screen\",\"msg\":\"on it\"},"
  "{\"id\":\"s2\",\"project\":\"api\",\"title\":\"schema\",\"msg\":\"dispatched\"}]}";

// ===== sdetail parsing =====

static void test_sdetail_joins_by_id(void) {
  buddy_rec_t b; seed(&b, 2);
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sdetail(SD_TWO, strlen(SD_TWO), &b, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("beacon", b.sessions[0].project);
  TEST_ASSERT_EQUAL_STRING("graph screen", b.sessions[0].title);
  TEST_ASSERT_EQUAL_STRING("on it", b.sessions[0].msg);
  TEST_ASSERT_EQUAL_STRING("api", b.sessions[1].project);
  TEST_ASSERT_EQUAL_STRING("dispatched", b.sessions[1].msg);
}

// The sessions frame is the only authority on which sessions exist: a detail row for an unknown id must
// not invent a session or scribble on an existing one.
static void test_sdetail_ignores_unknown_id(void) {
  buddy_rec_t b; seed(&b, 1);
  const char* f = "{\"v\":1,\"sdetail\":[{\"id\":\"s9\",\"project\":\"ghost\"}]}";
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sdetail(f, strlen(f), &b, &had));
  TEST_ASSERT_EQUAL_UINT8(1, b.session_count);
  TEST_ASSERT_EQUAL_STRING("", b.sessions[0].project);
}

// Omitted fields are sticky: a frame carrying only a new message must not blank a title still on screen.
static void test_sdetail_omitted_fields_are_sticky(void) {
  buddy_rec_t b; seed(&b, 1);
  bool had = false;
  const char* full = "{\"v\":1,\"sdetail\":[{\"id\":\"s1\",\"project\":\"beacon\",\"title\":\"t\",\"msg\":\"m1\"}]}";
  TEST_ASSERT_TRUE(hub_parse_sdetail(full, strlen(full), &b, &had));
  const char* partial = "{\"v\":1,\"sdetail\":[{\"id\":\"s1\",\"msg\":\"m2\"}]}";
  TEST_ASSERT_TRUE(hub_parse_sdetail(partial, strlen(partial), &b, &had));
  TEST_ASSERT_EQUAL_STRING("m2", b.sessions[0].msg);
  TEST_ASSERT_EQUAL_STRING("beacon", b.sessions[0].project);
  TEST_ASSERT_EQUAL_STRING("t", b.sessions[0].title);
}

static void test_sdetail_truncates_overlong_fields(void) {
  buddy_rec_t b; seed(&b, 1);
  char f[512];
  snprintf(f, sizeof(f),
           "{\"v\":1,\"sdetail\":[{\"id\":\"s1\",\"project\":\"%s\",\"title\":\"%s\",\"msg\":\"%s\"}]}",
           "PPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPPP", "TTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT",
           "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM");
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sdetail(f, strlen(f), &b, &had));
  TEST_ASSERT_EQUAL_UINT(BUDDY_PROJECT_LEN - 1, strlen(b.sessions[0].project));
  TEST_ASSERT_EQUAL_UINT(BUDDY_TITLE_LEN - 1, strlen(b.sessions[0].title));
  TEST_ASSERT_EQUAL_UINT(BUDDY_MSG_LEN - 1, strlen(b.sessions[0].msg));
}

static void test_sdetail_rejects_junk_and_wrong_version(void) {
  buddy_rec_t b; seed(&b, 1);
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sdetail("not json", 8, &b, &had));
  TEST_ASSERT_FALSE(had);
  const char* v2 = "{\"v\":2,\"sdetail\":[{\"id\":\"s1\",\"msg\":\"x\"}]}";
  TEST_ASSERT_FALSE(hub_parse_sdetail(v2, strlen(v2), &b, &had));
  TEST_ASSERT_FALSE(had);
  // A sessions frame is not an sdetail frame: dispatch must not treat them interchangeably.
  const char* sess = "{\"v\":1,\"sessions\":[{\"id\":\"s1\",\"label\":\"x\",\"state\":\"working\",\"ts\":1}]}";
  TEST_ASSERT_FALSE(hub_parse_sdetail(sess, strlen(sess), &b, &had));
  TEST_ASSERT_FALSE(had);
}

// ===== detail survives a sessions update =====

// The reason detail is re-attached by id rather than by index. Rows are newest-first, so an incoming
// sessions frame routinely REORDERS them; carrying detail positionally would show s1's message on s2.
static void test_detail_survives_session_reorder(void) {
  buddy_rec_t b; seed(&b, 2);
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sdetail(SD_TWO, strlen(SD_TWO), &b, &had));

  // s2 becomes the newest => the hub sends it first.
  const char* swapped =
    "{\"v\":1,\"sessions\":["
    "{\"id\":\"s2\",\"label\":\"api\",\"state\":\"working\",\"ts\":200},"
    "{\"id\":\"s1\",\"label\":\"beacon\",\"state\":\"idle\",\"ts\":100}]}";
  TEST_ASSERT_TRUE(hub_parse_sessions(swapped, strlen(swapped), &b, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("s2", b.sessions[0].id);
  TEST_ASSERT_EQUAL_STRING("api", b.sessions[0].project);
  TEST_ASSERT_EQUAL_STRING("dispatched", b.sessions[0].msg);
  TEST_ASSERT_EQUAL_STRING("s1", b.sessions[1].id);
  TEST_ASSERT_EQUAL_STRING("beacon", b.sessions[1].project);
  TEST_ASSERT_EQUAL_STRING("on it", b.sessions[1].msg);
}

// A genuinely new session must start blank rather than inheriting the detail of whoever held its slot.
static void test_new_session_does_not_inherit_detail(void) {
  buddy_rec_t b; seed(&b, 1);
  bool had = false;
  const char* d = "{\"v\":1,\"sdetail\":[{\"id\":\"s1\",\"project\":\"beacon\",\"msg\":\"mine\"}]}";
  TEST_ASSERT_TRUE(hub_parse_sdetail(d, strlen(d), &b, &had));

  const char* fresh =
    "{\"v\":1,\"sessions\":[{\"id\":\"s7\",\"label\":\"other\",\"state\":\"working\",\"ts\":9}]}";
  TEST_ASSERT_TRUE(hub_parse_sessions(fresh, strlen(fresh), &b, &had));
  TEST_ASSERT_EQUAL_STRING("s7", b.sessions[0].id);
  TEST_ASSERT_EQUAL_STRING("", b.sessions[0].project);
  TEST_ASSERT_EQUAL_STRING("", b.sessions[0].msg);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_sdetail_joins_by_id);
  RUN_TEST(test_sdetail_ignores_unknown_id);
  RUN_TEST(test_sdetail_omitted_fields_are_sticky);
  RUN_TEST(test_sdetail_truncates_overlong_fields);
  RUN_TEST(test_sdetail_rejects_junk_and_wrong_version);
  RUN_TEST(test_detail_survives_session_reorder);
  RUN_TEST(test_new_session_does_not_inherit_detail);
  return UNITY_END();
}
