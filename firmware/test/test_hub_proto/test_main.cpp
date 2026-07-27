#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/hub_proto.h"

void setUp(void) {}
void tearDown(void) {}

// --- reassembler capture harness ---
#define CAP_MAX 8
static char   g_frames[CAP_MAX][HUB_FRAME_MAX];
static size_t g_count;
static void cap_cb(const char* line, size_t len, void* user) {
  (void)user;
  if (g_count < CAP_MAX) { memcpy(g_frames[g_count], line, len); g_frames[g_count][len] = '\0'; g_count++; }
}
static void cap_reset(void) { g_count = 0; }

// Canonical tech.md §7.1 status frame (the device-facing schema is frozen).
static const char* FRAME_FULL =
  "{\"v\":1,\"usage\":{\"providers\":["
  "{\"id\":\"claude\",\"label\":\"CLAUDE\",\"h5\":{\"pct\":24,\"reset\":1717600000},"
  "\"d7\":{\"pct\":24,\"reset\":1717800000},\"stale\":true},"
  "{\"id\":\"codex\",\"label\":\"CODEX\",\"h5\":{\"pct\":1,\"reset\":1717590000},"
  "\"d7\":{\"pct\":29,\"reset\":1717800000}}]},"
  "\"buddy\":{\"running\":2,\"waiting\":1,\"tokens\":184502,\"context_pct\":42,"
  "\"entries\":[\"10:42 git push\",\"10:41 yarn test\"],"
  "\"prompt\":{\"id\":\"req_abc\",\"agent\":\"claude\",\"tool\":\"Bash\",\"hint\":\"rm -rf /tmp/build\"}}}";

// ===== reassembly =====

static void test_reassemble_single_frame(void) {
  cap_reset();
  hub_reassembler_t r; hub_reassembler_reset(&r);
  const char* in = "{\"v\":1}\n";
  hub_reassembler_feed(&r, in, strlen(in), cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(1, g_count);
  TEST_ASSERT_EQUAL_STRING("{\"v\":1}", g_frames[0]);
}

static void test_reassemble_two_frames_one_feed(void) {
  cap_reset();
  hub_reassembler_t r; hub_reassembler_reset(&r);
  const char* in = "{\"a\":1}\n{\"b\":2}\n";
  hub_reassembler_feed(&r, in, strlen(in), cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(2, g_count);
  TEST_ASSERT_EQUAL_STRING("{\"a\":1}", g_frames[0]);
  TEST_ASSERT_EQUAL_STRING("{\"b\":2}", g_frames[1]);
}

static void test_reassemble_split_across_feeds(void) {
  cap_reset();
  hub_reassembler_t r; hub_reassembler_reset(&r);
  hub_reassembler_feed(&r, "{\"hel", 5, cap_cb, NULL);   // frame split mid-way over BLE writes
  hub_reassembler_feed(&r, "lo\":1}", 6, cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(0, g_count);                  // no newline yet
  hub_reassembler_feed(&r, "\n", 1, cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(1, g_count);
  TEST_ASSERT_EQUAL_STRING("{\"hello\":1}", g_frames[0]);
}

static void test_reassemble_crlf_and_empty(void) {
  cap_reset();
  hub_reassembler_t r; hub_reassembler_reset(&r);
  const char* in = "{\"x\":1}\r\n\n{\"y\":2}\n";   // CRLF stripped; the empty line skipped
  hub_reassembler_feed(&r, in, strlen(in), cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(2, g_count);
  TEST_ASSERT_EQUAL_STRING("{\"x\":1}", g_frames[0]);
  TEST_ASSERT_EQUAL_STRING("{\"y\":2}", g_frames[1]);
}

static void test_reassemble_overflow_then_recover(void) {
  cap_reset();
  hub_reassembler_t r; hub_reassembler_reset(&r);
  char big[HUB_FRAME_MAX + 200];
  memset(big, 'x', sizeof(big)); big[sizeof(big) - 1] = '\n';   // one oversize frame
  hub_reassembler_feed(&r, big, sizeof(big), cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(0, g_count);     // dropped
  TEST_ASSERT_EQUAL_UINT32(1, r.drops);
  const char* ok = "{\"ok\":1}\n";           // next frame parses fine
  hub_reassembler_feed(&r, ok, strlen(ok), cap_cb, NULL);
  TEST_ASSERT_EQUAL_size_t(1, g_count);
  TEST_ASSERT_EQUAL_STRING("{\"ok\":1}", g_frames[0]);
}

// ===== status parse =====

static void test_parse_full_frame(void) {
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(FRAME_FULL, strlen(FRAME_FULL), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(hu); TEST_ASSERT_TRUE(hb);
  TEST_ASSERT_EQUAL_UINT8(2, u.count);
  TEST_ASSERT_EQUAL_STRING("claude", u.p[0].id);
  TEST_ASSERT_EQUAL_STRING("CLAUDE", u.p[0].label);
  TEST_ASSERT_EQUAL_INT16(24, u.p[0].h5.pct);
  TEST_ASSERT_EQUAL_UINT32(1717600000, u.p[0].h5.reset);
  TEST_ASSERT_TRUE(u.p[0].stale);                  // "stale":true
  TEST_ASSERT_EQUAL_STRING("codex", u.p[1].id);
  TEST_ASSERT_EQUAL_STRING("CODEX", u.p[1].label);
  TEST_ASSERT_EQUAL_INT16(29, u.p[1].d7.pct);
  TEST_ASSERT_FALSE(u.p[1].stale);                 // absent => live
  TEST_ASSERT_EQUAL_UINT8(2, b.running);
  TEST_ASSERT_EQUAL_UINT8(1, b.waiting);
  TEST_ASSERT_EQUAL_UINT32(184502, b.tokens);
  TEST_ASSERT_EQUAL_UINT8(42, b.context_pct);
  TEST_ASSERT_EQUAL_UINT8(2, b.entry_count);
  TEST_ASSERT_EQUAL_STRING("10:42 git push", b.entries[0]);
  TEST_ASSERT_TRUE(b.prompt.present);
  TEST_ASSERT_EQUAL_STRING("req_abc", b.prompt.id);
  TEST_ASSERT_EQUAL_STRING("claude", b.prompt.agent);   // additive agent field
  TEST_ASSERT_EQUAL_STRING("Bash", b.prompt.tool);
  TEST_ASSERT_EQUAL_STRING("rm -rf /tmp/build", b.prompt.hint);
}

// Build a providers array of `n` trivial entries (id "pN"/label "PN"). Used for count cases.
static void make_providers(char* buf, size_t cap, int n) {
  size_t o = (size_t)snprintf(buf, cap, "{\"v\":1,\"usage\":{\"providers\":[");
  for (int i = 0; i < n; i++) {
    o += (size_t)snprintf(buf + o, cap - o,
      "%s{\"id\":\"p%d\",\"label\":\"P%d\",\"h5\":{\"pct\":%d,\"reset\":1},\"d7\":{\"pct\":%d,\"reset\":2}}",
      i ? "," : "", i, i, i, i + 10);
  }
  snprintf(buf + o, cap - o, "]}}");
}

// Table: 0/1/2/4 providers parse to that count; 5+ truncate to USAGE_PROVIDERS_MAX (4).
static void test_parse_providers_count_table(void) {
  struct { int sent, expect; } c[] = { {0,0}, {1,1}, {2,2}, {4,4}, {5,4}, {7,4} };
  for (size_t k = 0; k < sizeof(c)/sizeof(c[0]); k++) {
    char j[1024]; make_providers(j, sizeof(j), c[k].sent);
    usage_rec_t u; buddy_rec_t b; bool hu, hb;
    memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
    TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
    TEST_ASSERT_TRUE(hu);
    TEST_ASSERT_EQUAL_UINT8(c[k].expect, u.count);
    if (c[k].expect > 0) {
      TEST_ASSERT_EQUAL_STRING("p0", u.p[0].id);
      TEST_ASSERT_EQUAL_INT16(0, u.p[0].h5.pct);
      TEST_ASSERT_EQUAL_INT16(10, u.p[0].d7.pct);
    }
    if (c[k].expect == USAGE_PROVIDERS_MAX)
      TEST_ASSERT_EQUAL_STRING("p3", u.p[3].id);   // first 4 kept, extras dropped
  }
}

static void test_parse_id_label_truncation(void) {
  // id 20 chars, label 20 chars => truncated to capacity-1 (12 / 10).
  const char* j = "{\"v\":1,\"usage\":{\"providers\":[{"
                  "\"id\":\"abcdefghijklmnopqrst\",\"label\":\"ABCDEFGHIJKLMNOPQRST\","
                  "\"h5\":{\"pct\":5,\"reset\":1},\"d7\":{\"pct\":6,\"reset\":2}}]}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_UINT8(1, u.count);
  TEST_ASSERT_EQUAL_size_t(USAGE_ID_LEN - 1, strlen(u.p[0].id));
  TEST_ASSERT_EQUAL_STRING_LEN("abcdefghijkl", u.p[0].id, USAGE_ID_LEN - 1);
  TEST_ASSERT_EQUAL_size_t(USAGE_LABEL_LEN - 1, strlen(u.p[0].label));
  TEST_ASSERT_EQUAL_STRING_LEN("ABCDEFGHIJ", u.p[0].label, USAGE_LABEL_LEN - 1);
}

static void test_parse_null_and_missing_windows(void) {
  // h5.pct explicitly null => -1; d7 window entirely absent => -1 (unavailable).
  const char* j = "{\"v\":1,\"usage\":{\"providers\":[{"
                  "\"id\":\"claude\",\"label\":\"CLAUDE\",\"h5\":{\"pct\":null,\"reset\":0}}]}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(hu); TEST_ASSERT_FALSE(hb);
  TEST_ASSERT_EQUAL_UINT8(1, u.count);
  TEST_ASSERT_EQUAL_INT16(-1, u.p[0].h5.pct);   // explicit JSON null
  TEST_ASSERT_EQUAL_INT16(-1, u.p[0].d7.pct);   // absent window
}

static void test_parse_stale_flag(void) {
  // #108: per-provider stale. Present+true => stale; absent => live (false).
  const char* j = "{\"v\":1,\"usage\":{\"providers\":["
                  "{\"id\":\"claude\",\"label\":\"CLAUDE\",\"stale\":true,\"h5\":{\"pct\":24,\"reset\":1},\"d7\":{\"pct\":32,\"reset\":2}},"
                  "{\"id\":\"codex\",\"label\":\"CODEX\",\"h5\":{\"pct\":1,\"reset\":3},\"d7\":{\"pct\":0,\"reset\":4}}]}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(hu);
  TEST_ASSERT_TRUE(u.p[0].stale);    // explicit "stale":true
  TEST_ASSERT_FALSE(u.p[1].stale);   // absent => live
  TEST_ASSERT_EQUAL_INT16(24, u.p[0].h5.pct);
}

// A usage block missing the providers array is malformed => rejected as a block: *had_usage stays
// false so the caller keeps the last values (parity with the pre-refactor whole-block reject).
static void test_parse_malformed_usage_keeps_last(void) {
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  const char* j1 = "{\"v\":1,\"usage\":{}}";                 // no providers key
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j1, strlen(j1), &u, &hu, &b, &hb));
  TEST_ASSERT_FALSE(hu);                                      // block rejected => keep last
  const char* j2 = "{\"v\":1,\"usage\":{\"providers\":\"nope\"}}";  // providers not an array
  memset(&u, 0, sizeof(u));
  TEST_ASSERT_TRUE(hub_parse_status(j2, strlen(j2), &u, &hu, &b, &hb));
  TEST_ASSERT_FALSE(hu);
}

static void test_parse_prompt_absent_is_idle(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"running\":0,\"waiting\":0,\"tokens\":10,\"context_pct\":5}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(hb);
  TEST_ASSERT_FALSE(b.prompt.present);            // absence of prompt => idle
}

// Additive prompt.agent (frozen wire): absent => empty; oversize => truncated to USAGE_ID_LEN-1.
static void test_parse_prompt_agent_absent(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"prompt\":{\"id\":\"p1\",\"tool\":\"Bash\",\"hint\":\"ls\"}}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(b.prompt.present);
  TEST_ASSERT_EQUAL_STRING("", b.prompt.agent);   // absent agent => empty string
}

static void test_parse_prompt_agent_oversize(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"prompt\":{\"id\":\"p1\",\"agent\":\"abcdefghijklmnop\","
                  "\"tool\":\"Bash\",\"hint\":\"ls\"}}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_size_t(USAGE_ID_LEN - 1, strlen(b.prompt.agent));
  TEST_ASSERT_EQUAL_STRING_LEN("abcdefghijkl", b.prompt.agent, USAGE_ID_LEN - 1);
}

// A full-frame resend repeating the SAME pending prompt must NOT reset the confirm state (#8),
// or the pending ack would no longer transition the prompt.
static void test_parse_same_prompt_preserves_pending(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"running\":0,\"waiting\":0,\"tokens\":0,\"context_pct\":0,"
                  "\"prompt\":{\"id\":\"p7\",\"tool\":\"Bash\",\"hint\":\"ls\"}}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  b.prompt.present = true; strcpy(b.prompt.id, "p7"); b.prompt.decision_state = PROMPT_PENDING;
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_UINT8(PROMPT_PENDING, b.prompt.decision_state);
}

// A different prompt id IS fresh to decide => reset to idle.
static void test_parse_new_prompt_resets_decision(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"running\":0,\"waiting\":0,\"tokens\":0,\"context_pct\":0,"
                  "\"prompt\":{\"id\":\"p8\",\"tool\":\"Bash\",\"hint\":\"ls\"}}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  b.prompt.present = true; strcpy(b.prompt.id, "p7"); b.prompt.decision_state = PROMPT_PENDING;
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_UINT8(PROMPT_IDLE_DECISION, b.prompt.decision_state);

  // queue advance: front p1 (qlen 2) -> next p2 (lone) resets decision_state and drops the badge
  const char* nxt = "{\"v\":1,\"buddy\":{\"prompt\":{\"id\":\"p2\",\"tool\":\"Write\",\"hint\":\"b\"}}}";
  hub_parse_status(nxt, strlen(nxt), &u, &hu, &b, &hb);
  TEST_ASSERT_EQUAL_STRING("p2", b.prompt.id);
  TEST_ASSERT_EQUAL_UINT8(PROMPT_IDLE_DECISION, b.prompt.decision_state);
  TEST_ASSERT_EQUAL_UINT8(1, b.prompt.queue_len);
}

static void test_parse_truncates_long_strings(void) {
  // id longer than BUDDY_ID_LEN-1 (23) must truncate, not overflow (hub mints <=23, but be safe).
  const char* j = "{\"v\":1,\"buddy\":{\"prompt\":{\"id\":\"0123456789ABCDEF0123456789\","
                  "\"tool\":\"Bash\",\"hint\":\"x\"}}}";
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(b.prompt.present);
  TEST_ASSERT_EQUAL_size_t(BUDDY_ID_LEN - 1, strlen(b.prompt.id));   // truncated to capacity-1
  TEST_ASSERT_EQUAL_STRING_LEN("0123456789ABCDEF0123456", b.prompt.id, BUDDY_ID_LEN - 1);
}

static void test_parse_entries_capped(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"entries\":[\"a\",\"b\",\"c\",\"d\",\"e\"]}}";  // > BUDDY_ENTRIES
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_UINT8(BUDDY_ENTRIES, b.entry_count);
}

static void test_parse_rejects_bad_version_and_garbage(void) {
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  const char* v2 = "{\"v\":2,\"usage\":{}}";
  TEST_ASSERT_FALSE(hub_parse_status(v2, strlen(v2), &u, &hu, &b, &hb));
  const char* nov = "{\"usage\":{}}";              // missing v
  TEST_ASSERT_FALSE(hub_parse_status(nov, strlen(nov), &u, &hu, &b, &hb));
  const char* junk = "not json at all";
  TEST_ASSERT_FALSE(hub_parse_status(junk, strlen(junk), &u, &hu, &b, &hb));
}

// ===== loc parse (issue #54) =====

static void test_parse_loc_present(void) {
  const char* j = "{\"v\":1,\"usage\":{},\"loc\":{\"lat\":37.76,\"lon\":-122.42,"
                  "\"tz\":\"America/Los_Angeles\",\"name\":\"Mission, San Francisco\"}}";
  hub_loc_t l; memset(&l, 0, sizeof(l));
  TEST_ASSERT_TRUE(hub_parse_loc(j, strlen(j), &l));
  TEST_ASSERT_FLOAT_WITHIN(0.001f, 37.76f, l.lat);
  TEST_ASSERT_FLOAT_WITHIN(0.001f, -122.42f, l.lon);
  TEST_ASSERT_EQUAL_STRING("America/Los_Angeles", l.tz);
  TEST_ASSERT_EQUAL_STRING("Mission, San Francisco", l.name);
}

static void test_parse_loc_only_frame(void) {
  // A loc-only frame: hub_parse_loc fills it, and hub_parse_status still accepts it (valid v:1) so
  // hub_task does not log "bad/ignored frame".
  const char* j = "{\"v\":1,\"loc\":{\"lat\":1.0,\"lon\":2.0,\"tz\":\"UTC\",\"name\":\"Nowhere\"}}";
  hub_loc_t l; memset(&l, 0, sizeof(l));
  TEST_ASSERT_TRUE(hub_parse_loc(j, strlen(j), &l));
  TEST_ASSERT_EQUAL_STRING("Nowhere", l.name);
  usage_rec_t u; buddy_rec_t b; bool hu, hb;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_FALSE(hu); TEST_ASSERT_FALSE(hb);
}

static void test_parse_loc_absent(void) {
  hub_loc_t l; memset(&l, 0, sizeof(l));
  TEST_ASSERT_FALSE(hub_parse_loc(FRAME_FULL, strlen(FRAME_FULL), &l));   // no "loc" block
  const char* v2 = "{\"v\":2,\"loc\":{\"name\":\"X\"}}";
  TEST_ASSERT_FALSE(hub_parse_loc(v2, strlen(v2), &l));                   // wrong major version
  const char* junk = "not json";
  TEST_ASSERT_FALSE(hub_parse_loc(junk, strlen(junk), &l));
}

static void test_parse_loc_truncates(void) {
  // name > 47 chars and tz > 39 chars must truncate to capacity-1, not overflow.
  const char* j = "{\"v\":1,\"loc\":{\"lat\":0,\"lon\":0,"
                  "\"tz\":\"0123456789012345678901234567890123456789ABCDEF\","
                  "\"name\":\"0123456789012345678901234567890123456789012345678901234567\"}}";
  hub_loc_t l; memset(&l, 0, sizeof(l));
  TEST_ASSERT_TRUE(hub_parse_loc(j, strlen(j), &l));
  TEST_ASSERT_EQUAL_size_t(sizeof(l.tz) - 1, strlen(l.tz));
  TEST_ASSERT_EQUAL_size_t(sizeof(l.name) - 1, strlen(l.name));
}

// ===== command build =====

static void test_build_permission_roundtrips(void) {
  char buf[128];
  size_t n = hub_build_permission(buf, sizeof(buf), "req_abc", true);
  TEST_ASSERT_GREATER_THAN_size_t(0, n);
  TEST_ASSERT_EQUAL_CHAR('\n', buf[n - 1]);        // newline-terminated
  TEST_ASSERT_EQUAL_CHAR('\0', buf[n]);
  // re-parse to assert shape (id echo + decision)
  usage_rec_t u; buddy_rec_t b; bool hu, hb; (void)u; (void)b; (void)hu; (void)hb;
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"cmd\":\"permission\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"id\":\"req_abc\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"decision\":\"approve\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"v\":1"));
}

static void test_build_permission_deny(void) {
  char buf[128];
  hub_build_permission(buf, sizeof(buf), "req_x", false);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"decision\":\"deny\""));
}

static void test_build_overflow_returns_zero(void) {
  char buf[8];                                     // too small for any valid frame
  TEST_ASSERT_EQUAL_size_t(0, hub_build_permission(buf, sizeof(buf), "req_abc", true));
}

// hub_build_open (issue #110, P2-b)
static void test_build_open_frame(void) {
  char buf[128];
  size_t n = hub_build_open(buf, sizeof(buf), "s3");
  TEST_ASSERT_GREATER_THAN_size_t(0, n);
  TEST_ASSERT_EQUAL_CHAR('\n', buf[n - 1]);          // newline-terminated (framing rule)
  TEST_ASSERT_EQUAL_CHAR('\0', buf[n]);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"v\":1"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"cmd\":\"open\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"id\":\"s3\""));
}

static void test_build_open_null_returns_zero(void) {
  char buf[64];
  TEST_ASSERT_EQUAL_size_t(0, hub_build_open(buf, sizeof(buf), nullptr));
  TEST_ASSERT_EQUAL_size_t(0, hub_build_open(nullptr, sizeof(buf), "s3"));
  TEST_ASSERT_EQUAL_size_t(0, hub_build_open(buf, 0, "s3"));
}

// ===== ack / err =====

static void test_parse_ack_ok(void) {
  const char* j = "{\"v\":1,\"ack\":\"req_abc\",\"ok\":true}";
  hub_ack_t a; memset(&a, 0, sizeof(a));
  TEST_ASSERT_TRUE(hub_parse_ack(j, strlen(j), &a));
  TEST_ASSERT_FALSE(a.is_err);
  TEST_ASSERT_TRUE(a.ok);
  TEST_ASSERT_EQUAL_STRING("req_abc", a.id);
}

static void test_parse_err(void) {
  const char* j = "{\"v\":1,\"err\":\"unknown_prompt_id\",\"id\":\"req_xyz\"}";
  hub_ack_t a; memset(&a, 0, sizeof(a));
  TEST_ASSERT_TRUE(hub_parse_ack(j, strlen(j), &a));
  TEST_ASSERT_TRUE(a.is_err);
  TEST_ASSERT_FALSE(a.ok);
  TEST_ASSERT_EQUAL_STRING("req_xyz", a.id);
}

static void test_parse_ack_not_ok(void) {
  // ok:false = decision did not apply (late/superseded); parses true, is_err=false, ok=false (issue #8).
  const char* j = "{\"v\":1,\"ack\":\"req_abc\",\"ok\":false}";
  hub_ack_t a; memset(&a, 0, sizeof(a));
  TEST_ASSERT_TRUE(hub_parse_ack(j, strlen(j), &a));
  TEST_ASSERT_FALSE(a.is_err);
  TEST_ASSERT_FALSE(a.ok);
  TEST_ASSERT_EQUAL_STRING("req_abc", a.id);
}

static void test_parse_ack_neither(void) {
  const char* j = "{\"v\":1,\"usage\":{}}";        // a status frame is not an ack
  hub_ack_t a; memset(&a, 0, sizeof(a));
  TEST_ASSERT_FALSE(hub_parse_ack(j, strlen(j), &a));
}

// ===== ack state transition (hub_apply_ack, issue #8) =====

static void mk_pending_prompt(buddy_rec_t* b, const char* id) {
  memset(b, 0, sizeof(*b));
  b->prompt.present = true;
  b->prompt.decision_state = PROMPT_PENDING;
  strncpy(b->prompt.id, id, BUDDY_ID_LEN - 1);
}

static void test_apply_ack_ok_holds_prompt(void) {
  buddy_rec_t b; mk_pending_prompt(&b, "req_abc");
  hub_ack_t a = { "req_abc", true, false };
  TEST_ASSERT_TRUE(hub_apply_ack(&b, &a));
  TEST_ASSERT_EQUAL_UINT8(PROMPT_SENT_OK, b.prompt.decision_state);
  TEST_ASSERT_TRUE(b.prompt.present);                   // kept: the device tick clears it after the confirm-hold beat (issue #12)
}

static void test_apply_ack_not_ok_keeps_prompt(void) {
  buddy_rec_t b; mk_pending_prompt(&b, "req_abc");
  hub_ack_t a = { "req_abc", false, false };            // ok:false (late/superseded)
  TEST_ASSERT_TRUE(hub_apply_ack(&b, &a));
  TEST_ASSERT_EQUAL_UINT8(PROMPT_TOO_LATE, b.prompt.decision_state);
  TEST_ASSERT_TRUE(b.prompt.present);                   // kept so the UI can warn, never shows success
}

static void test_apply_ack_err_keeps_prompt(void) {
  buddy_rec_t b; mk_pending_prompt(&b, "req_abc");
  hub_ack_t a = { "req_abc", false, true };             // err frame
  TEST_ASSERT_TRUE(hub_apply_ack(&b, &a));
  TEST_ASSERT_EQUAL_UINT8(PROMPT_TOO_LATE, b.prompt.decision_state);
  TEST_ASSERT_TRUE(b.prompt.present);
}

static void test_apply_ack_mismatched_id_ignored(void) {
  buddy_rec_t b; mk_pending_prompt(&b, "req_abc");
  hub_ack_t a = { "req_other", true, false };
  TEST_ASSERT_FALSE(hub_apply_ack(&b, &a));             // stale id => no change
  TEST_ASSERT_EQUAL_UINT8(PROMPT_PENDING, b.prompt.decision_state);
  TEST_ASSERT_TRUE(b.prompt.present);
}

static void test_apply_ack_not_pending_ignored(void) {
  buddy_rec_t b; mk_pending_prompt(&b, "req_abc");
  b.prompt.decision_state = PROMPT_IDLE_DECISION;       // no decision awaiting an ack
  hub_ack_t a = { "req_abc", true, false };
  TEST_ASSERT_FALSE(hub_apply_ack(&b, &a));
  TEST_ASSERT_TRUE(b.prompt.present);
}

// ===== qlen / queue_len =====

static void test_parse_prompt_qlen(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"prompt\":"
                  "{\"id\":\"p1\",\"tool\":\"Bash\",\"hint\":\"ls\",\"qlen\":3}}}";
  usage_rec_t u{}; buddy_rec_t b{}; bool hu=false, hb=false;
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_TRUE(b.prompt.present);
  TEST_ASSERT_EQUAL_UINT8(3, b.prompt.queue_len);
}

static void test_parse_prompt_qlen_absent_defaults_one(void) {
  const char* j = "{\"v\":1,\"buddy\":{\"prompt\":"
                  "{\"id\":\"p1\",\"tool\":\"Bash\",\"hint\":\"ls\"}}}";
  usage_rec_t u{}; buddy_rec_t b{}; bool hu=false, hb=false;
  TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
  TEST_ASSERT_EQUAL_UINT8(1, b.prompt.queue_len);
}

static void test_parse_prompt_qlen_clamps_out_of_range(void) {
  usage_rec_t u{}; buddy_rec_t b{}; bool hu=false, hb=false;
  struct { const char* qlen; uint8_t want; } cases[] = {
      {"0", 1}, {"-3", 1}, {"256", 255}, {"1000", 255}, {"2", 2},
  };
  for (auto& c : cases) {
    char j[128];
    snprintf(j, sizeof(j),
        "{\"v\":1,\"buddy\":{\"prompt\":{\"id\":\"p1\",\"tool\":\"B\",\"hint\":\"h\",\"qlen\":%s}}}", c.qlen);
    TEST_ASSERT_TRUE(hub_parse_status(j, strlen(j), &u, &hu, &b, &hb));
    TEST_ASSERT_EQUAL_UINT8(c.want, b.prompt.queue_len);
  }
}

// ===== sessions parse =====

void test_parse_sessions_basic(void) {
  const char* j = "{\"v\":1,\"sessions\":["
    "{\"id\":\"s3\",\"label\":\"beacon \xC2\xB7 fix/109\",\"state\":\"attention\",\"ts\":1719400000},"
    "{\"id\":\"s1\",\"label\":\"api \xC2\xB7 main\",\"state\":\"working\",\"ts\":1719399860}]}";
  buddy_rec_t b; memset(&b, 0, sizeof(b));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sessions(j, strlen(j), &b, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT8(2, b.session_count);
  TEST_ASSERT_EQUAL_STRING("s3", b.sessions[0].id);
  TEST_ASSERT_EQUAL_UINT8(BST_ATTENTION, b.sessions[0].state);
  TEST_ASSERT_EQUAL_UINT8(BST_WORKING, b.sessions[1].state);
  TEST_ASSERT_EQUAL_UINT32(1719400000u, b.sessions[0].ts);
  TEST_ASSERT_EQUAL_STRING("beacon \xC2\xB7 fix/109", b.sessions[0].label);
  TEST_ASSERT_EQUAL_UINT32(1719399860u, b.sessions[1].ts);
}

void test_parse_sessions_caps_and_truncates(void) {
  // 7 sessions, an over-length label, an unknown state.
  const char* j = "{\"v\":1,\"sessions\":["
    "{\"id\":\"s1\",\"label\":\"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\",\"state\":\"glorp\",\"ts\":7},"
    "{\"id\":\"s2\",\"label\":\"x\",\"state\":\"idle\",\"ts\":6},"
    "{\"id\":\"s3\",\"label\":\"x\",\"state\":\"idle\",\"ts\":5},"
    "{\"id\":\"s4\",\"label\":\"x\",\"state\":\"idle\",\"ts\":4},"
    "{\"id\":\"s5\",\"label\":\"x\",\"state\":\"idle\",\"ts\":3},"
    "{\"id\":\"s6\",\"label\":\"x\",\"state\":\"idle\",\"ts\":2},"
    "{\"id\":\"s7\",\"label\":\"x\",\"state\":\"idle\",\"ts\":1}]}";
  buddy_rec_t b; memset(&b, 0, sizeof(b));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sessions(j, strlen(j), &b, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT8(BUDDY_SESSIONS_MAX, b.session_count);          // capped at 5
  TEST_ASSERT_TRUE(strlen(b.sessions[0].label) <= BUDDY_LABEL_LEN - 1);  // truncated
  TEST_ASSERT_EQUAL_UINT8(BST_WORKING, b.sessions[0].state);             // unknown => working
}

void test_parse_sessions_rejects_bad_version(void) {
  const char* j = "{\"v\":2,\"sessions\":[]}";
  buddy_rec_t b; memset(&b, 0, sizeof(b));
  bool had = false;
  TEST_ASSERT_FALSE(hub_parse_sessions(j, strlen(j), &b, &had));
  TEST_ASSERT_FALSE(had);
}

void test_parse_sessions_question_state(void) {
  const char* j = "{\"v\":1,\"sessions\":["
    "{\"id\":\"s9\",\"label\":\"myrepo \xC2\xB7 feat/ask\",\"state\":\"question\",\"ts\":1719401000}]}";
  buddy_rec_t b; memset(&b, 0, sizeof(b));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sessions(j, strlen(j), &b, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT8(1, b.session_count);
  TEST_ASSERT_EQUAL_STRING("s9", b.sessions[0].id);
  TEST_ASSERT_EQUAL_UINT8(BST_QUESTION, b.sessions[0].state);
  TEST_ASSERT_EQUAL_UINT32(1719401000u, b.sessions[0].ts);
}

// Additive session.agent (frozen wire): present stored, absent => empty, oversize => truncated.
void test_parse_sessions_agent(void) {
  const char* j = "{\"v\":1,\"sessions\":["
    "{\"id\":\"s1\",\"agent\":\"codex\",\"label\":\"api\",\"state\":\"working\",\"ts\":9},"
    "{\"id\":\"s2\",\"label\":\"web\",\"state\":\"idle\",\"ts\":8},"
    "{\"id\":\"s3\",\"agent\":\"abcdefghijklmnop\",\"label\":\"db\",\"state\":\"idle\",\"ts\":7}]}";
  buddy_rec_t b; memset(&b, 0, sizeof(b));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sessions(j, strlen(j), &b, &had));
  TEST_ASSERT_EQUAL_UINT8(3, b.session_count);
  TEST_ASSERT_EQUAL_STRING("codex", b.sessions[0].agent);   // present
  TEST_ASSERT_EQUAL_STRING("", b.sessions[1].agent);        // absent => empty
  TEST_ASSERT_EQUAL_size_t(USAGE_ID_LEN - 1, strlen(b.sessions[2].agent));   // oversize truncated
}

// ===== comps frame (hub_parse_comps / hub_build_comps_ack) =====

static void test_comps_parse_happy_path(void) {
  const char* j = "{\"v\":1,\"comps\":{\"rev\":5,\"slots\":{\"home\":[\"clock\",\"fin.sp500\",\"ice\",\"agents\"]}}}";
  uint32_t rev = 0; comp_list_t l; bool explicit_empty = true; const char* err = "unset";
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(j, strlen(j), &rev, "home", &l, &explicit_empty, &err));
  TEST_ASSERT_EQUAL_UINT32(5, rev);
  TEST_ASSERT_FALSE(explicit_empty);
  TEST_ASSERT_EQUAL_UINT8(4, l.count);
  TEST_ASSERT_EQUAL_STRING("clock", l.ids[0]);
  TEST_ASSERT_EQUAL_STRING("fin",   l.ids[1]);
  TEST_ASSERT_EQUAL_STRING("sp500", l.args[1]);
  TEST_ASSERT_EQUAL_STRING("ice",    l.ids[2]);
  TEST_ASSERT_EQUAL_STRING("agents", l.ids[3]);
}

// A frame this frame simply does not carry `face_id` for: ERR_NONE, *out empty, *explicit_empty=false,
// and the caller does nothing (no ack) -- the one place the pages analogy breaks (a missing "list" is
// malformed for pages; a missing face here is just "nothing to say about this face").
static void test_comps_parse_absent_face_is_not_an_error(void) {
  const char* j = "{\"v\":1,\"comps\":{\"rev\":2,\"slots\":{\"watch\":[\"clock\"]}}}";
  uint32_t rev = 0; comp_list_t l; bool explicit_empty = true; const char* err = "unset";
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(j, strlen(j), &rev, "home", &l, &explicit_empty, &err));
  TEST_ASSERT_EQUAL_UINT8(0, l.count);
  TEST_ASSERT_FALSE(explicit_empty);
}

static void test_comps_parse_explicit_empty_array(void) {
  const char* j = "{\"v\":1,\"comps\":{\"rev\":9,\"slots\":{\"home\":[]}}}";
  uint32_t rev = 0; comp_list_t l; bool explicit_empty = false; const char* err = "unset";
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(j, strlen(j), &rev, "home", &l, &explicit_empty, &err));
  TEST_ASSERT_EQUAL_UINT8(0, l.count);
  TEST_ASSERT_TRUE(explicit_empty);
}

static void test_comps_parse_rejects_malformed(void) {
  uint32_t rev = 0; comp_list_t l; bool ee = false; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps("nope", 4, &rev, "home", &l, &ee, &err));
  TEST_ASSERT_EQUAL_STRING("malformed", err);

  const char* v2 = "{\"v\":2,\"comps\":{\"rev\":1,\"slots\":{\"home\":[]}}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps(v2, strlen(v2), &rev, "home", &l, &ee, &err));

  const char* norev = "{\"v\":1,\"comps\":{\"slots\":{\"home\":[]}}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps(norev, strlen(norev), &rev, "home", &l, &ee, &err));

  const char* noslots = "{\"v\":1,\"comps\":{\"rev\":1}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps(noslots, strlen(noslots), &rev, "home", &l, &ee, &err));

  const char* notarr = "{\"v\":1,\"comps\":{\"rev\":1,\"slots\":{\"home\":\"nope\"}}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps(notarr, strlen(notarr), &rev, "home", &l, &ee, &err));

  // A pages frame is not a comps frame.
  const char* pages = "{\"v\":1,\"pages\":{\"rev\":1,\"list\":[{\"id\":\"home\"}]}}";
  TEST_ASSERT_EQUAL_INT(ERR_PARSE, hub_parse_comps(pages, strlen(pages), &rev, "home", &l, &ee, &err));
}

// An unknown FACE key is simply not read (this test asks for "home" while the frame carries only
// "watch" -- see test_comps_parse_absent_face_is_not_an_error). Here we confirm the converse: a frame
// naming both an unknown face and "home" still parses "home" correctly.
static void test_comps_parse_ignores_other_faces(void) {
  const char* j = "{\"v\":1,\"comps\":{\"rev\":3,\"slots\":{\"watch\":[\"clock\"],\"home\":[\"ice\"]}}}";
  uint32_t rev = 0; comp_list_t l; bool ee = true; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(j, strlen(j), &rev, "home", &l, &ee, &err));
  TEST_ASSERT_EQUAL_UINT8(1, l.count);
  TEST_ASSERT_EQUAL_STRING("ice", l.ids[0]);
  TEST_ASSERT_FALSE(ee);
}

// Charset validity is NOT the parser's job (comp_list_resolve rule 7 owns it) -- but a non-string / an
// unsplittable wire entry ("FIN!" survives structurally; a bare non-string element does not) must not
// crash or fail the whole frame. Out-of-alphabet ids parse through and are dropped downstream by resolve
// (test_comp_list covers that); this test pins the parser's tolerant half of that contract.
static void test_comps_parse_tolerates_bad_entries_without_failing_frame(void) {
  const char* j = "{\"v\":1,\"comps\":{\"rev\":1,\"slots\":{\"home\":[\"FIN!\",42,\"ice.\",\"agents\"]}}}";
  uint32_t rev = 0; comp_list_t l; bool ee = true; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(j, strlen(j), &rev, "home", &l, &ee, &err));
  TEST_ASSERT_FALSE(ee);            // the wire array was non-empty (4 elements), even though most drop
  // "FIN!" splits fine structurally (no dot) so it survives to *out; 42 (non-string) and "ice." (trailing
  // dot) are dropped by the parser itself; "agents" survives.
  TEST_ASSERT_EQUAL_UINT8(2, l.count);
  TEST_ASSERT_EQUAL_STRING("FIN!",   l.ids[0]);
  TEST_ASSERT_EQUAL_STRING("agents", l.ids[1]);
}

static void test_comps_build_ack(void) {
  char buf[96];
  size_t n = hub_build_comps_ack(buf, sizeof(buf), 5, true, NULL, 4);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL('\n', buf[n - 1]);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"cmd\":\"comps_ack\""));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"rev\":5"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"count\":4"));

  n = hub_build_comps_ack(buf, sizeof(buf), 5, false, "malformed", 0);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"ok\":false"));
  TEST_ASSERT_NOT_NULL(strstr(buf, "\"err\":\"malformed\""));
  TEST_ASSERT_NULL(strstr(buf, "\"count\""));
  TEST_ASSERT_EQUAL_size_t(0, hub_build_comps_ack(buf, 4, 5, true, NULL, 1));   // overflow => 0
}

// The synthetic worst case (design §6.2): 2 faces x 6 one-slot entries, each entry the maximum
// "id.arg" = 11 + 1 + 15 chars, face id 11 chars, rev at uint32 max. Must stay comfortably under
// HUB_FRAME_MAX (1024) with no chunking -- 437 B by the design's derivation.
static void test_comps_worst_case_frame_fits_under_ceiling(void) {
  char entry[COMP_ENTRY_LEN];
  snprintf(entry, sizeof(entry), "%s.%s", "abcdefghijk" /*11*/, "abcdefghijklmno" /*15*/);
  char face1[16], face2[16];
  snprintf(face1, sizeof(face1), "%.11s", "aaaaaaaaaaa");
  snprintf(face2, sizeof(face2), "%.11s", "bbbbbbbbbbb");

  char json[HUB_FRAME_MAX];
  int n = snprintf(json, sizeof(json),
    "{\"v\":1,\"comps\":{\"rev\":4294967295,\"slots\":{"
    "\"%s\":[\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"],"
    "\"%s\":[\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"]}}}",
    face1, entry, entry, entry, entry, entry, entry,
    face2, entry, entry, entry, entry, entry, entry);
  TEST_ASSERT_TRUE(n > 0 && (size_t)n < HUB_FRAME_MAX);
  TEST_ASSERT_LESS_THAN(1024, n);

  // And it still parses cleanly for one of the two faces (duplicate ids across the two faces are legal
  // -- each face resolves independently).
  uint32_t rev = 0; comp_list_t l; bool ee = false; const char* err = NULL;
  TEST_ASSERT_EQUAL_INT(ERR_NONE, hub_parse_comps(json, (size_t)n, &rev, face1, &l, &ee, &err));
  TEST_ASSERT_EQUAL_UINT32(4294967295u, rev);
  TEST_ASSERT_EQUAL_UINT8(COMP_SLOTS_MAX, l.count);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_reassemble_single_frame);
  RUN_TEST(test_reassemble_two_frames_one_feed);
  RUN_TEST(test_reassemble_split_across_feeds);
  RUN_TEST(test_reassemble_crlf_and_empty);
  RUN_TEST(test_reassemble_overflow_then_recover);
  RUN_TEST(test_parse_full_frame);
  RUN_TEST(test_parse_providers_count_table);
  RUN_TEST(test_parse_id_label_truncation);
  RUN_TEST(test_parse_null_and_missing_windows);
  RUN_TEST(test_parse_stale_flag);
  RUN_TEST(test_parse_malformed_usage_keeps_last);
  RUN_TEST(test_parse_prompt_absent_is_idle);
  RUN_TEST(test_parse_prompt_agent_absent);
  RUN_TEST(test_parse_prompt_agent_oversize);
  RUN_TEST(test_parse_same_prompt_preserves_pending);
  RUN_TEST(test_parse_new_prompt_resets_decision);
  RUN_TEST(test_parse_truncates_long_strings);
  RUN_TEST(test_parse_entries_capped);
  RUN_TEST(test_parse_rejects_bad_version_and_garbage);
  RUN_TEST(test_parse_loc_present);
  RUN_TEST(test_parse_loc_only_frame);
  RUN_TEST(test_parse_loc_absent);
  RUN_TEST(test_parse_loc_truncates);
  RUN_TEST(test_build_permission_roundtrips);
  RUN_TEST(test_build_permission_deny);
  RUN_TEST(test_build_overflow_returns_zero);
  RUN_TEST(test_build_open_frame);
  RUN_TEST(test_build_open_null_returns_zero);
  RUN_TEST(test_parse_ack_ok);
  RUN_TEST(test_parse_ack_not_ok);
  RUN_TEST(test_parse_err);
  RUN_TEST(test_parse_ack_neither);
  RUN_TEST(test_apply_ack_ok_holds_prompt);
  RUN_TEST(test_apply_ack_not_ok_keeps_prompt);
  RUN_TEST(test_apply_ack_err_keeps_prompt);
  RUN_TEST(test_apply_ack_mismatched_id_ignored);
  RUN_TEST(test_apply_ack_not_pending_ignored);
  RUN_TEST(test_parse_prompt_qlen);
  RUN_TEST(test_parse_prompt_qlen_absent_defaults_one);
  RUN_TEST(test_parse_prompt_qlen_clamps_out_of_range);
  RUN_TEST(test_parse_sessions_basic);
  RUN_TEST(test_parse_sessions_caps_and_truncates);
  RUN_TEST(test_parse_sessions_rejects_bad_version);
  RUN_TEST(test_parse_sessions_question_state);
  RUN_TEST(test_parse_sessions_agent);
  RUN_TEST(test_comps_parse_happy_path);
  RUN_TEST(test_comps_parse_absent_face_is_not_an_error);
  RUN_TEST(test_comps_parse_explicit_empty_array);
  RUN_TEST(test_comps_parse_rejects_malformed);
  RUN_TEST(test_comps_parse_ignores_other_faces);
  RUN_TEST(test_comps_parse_tolerates_bad_entries_without_failing_frame);
  RUN_TEST(test_comps_build_ack);
  RUN_TEST(test_comps_worst_case_frame_fits_under_ceiling);
  return UNITY_END();
}
