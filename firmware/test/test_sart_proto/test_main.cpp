#include <unity.h>
#include <ArduinoJson.h>
#include <stdio.h>
#include <string.h>
#include "core/hub_proto.h"
#include "core/datastore.h"
#include "core/records.h"
#include "config/ticker_table.h"

// WS-0 (album art plan §4): the sart/sart_stat wire (CONTRACT.md §A4/§B4), the sonos_art_rec_t
// DataStore accessors, and the device report (`report what:"device"`, D-1). Mirrors test_sonos /
// test_hub_report's shape.

void setUp(void) { ticker_table_init(); datastore_init(); }
void tearDown(void) {}

// ===================== hub_parse_sart: S1 (art available) =====================

static const char* S1_FULL =
  "{\"v\":1,\"sart\":{\"gen\":7,"
  "\"url\":\"http://192.168.1.42:54321/a/0123456789abcdef0123456789abcdef\"}}";

static void test_sart_parses_s1_full_frame(void) {
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(S1_FULL, strlen(S1_FULL), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT32(7, out.gen);
  TEST_ASSERT_TRUE(out.has_url);
  TEST_ASSERT_EQUAL_STRING("http://192.168.1.42:54321/a/0123456789abcdef0123456789abcdef", out.url);
}

// Byte-exact fixture shared with hub/Tests/BeaconHubKitTests/ProtocolTests.swift
// testSonosArtFrameByteExactRoundTrip -- the SAME literal on both sides (design §2.2's S1 example), so a
// future change that breaks one representation breaks both (plan WS-0 required coverage).
static const char* S1_SHARED_FIXTURE =
  "{\"sart\":{\"gen\":7,\"url\":\"http://192.168.1.42:54321/a/0123456789abcdef0123456789abcdef\"},\"v\":1}";

static void test_sart_byte_exact_round_trip_matches_swift_fixture(void) {
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(S1_SHARED_FIXTURE, strlen(S1_SHARED_FIXTURE), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT32(7, out.gen);
  TEST_ASSERT_TRUE(out.has_url);
  TEST_ASSERT_EQUAL_STRING("http://192.168.1.42:54321/a/0123456789abcdef0123456789abcdef", out.url);
}

// S1 at the cap: gen = UINT32_MAX (10 digits), url exactly 96 chars (SONOS_ART_URL_LEN-1). The encoded
// wire form (built the same way the hub's JSONEncoder(.sortedKeys) would: {"sart":{"gen":...,"url":
// "..."},"v":1}\n) must be EXACTLY 139 bytes (design §2.3) -- and the parser must accept it (not reject
// at the boundary) and preserve the url losslessly.
static void test_sart_s1_at_cap_is_139_bytes_and_parses(void) {
  char url[SONOS_ART_URL_LEN]; // 97 = 96 chars + NUL
  memset(url, '1', SONOS_ART_URL_LEN - 1);
  memcpy(url, "http://", 7);                 // keep the charset realistic; length is what's under test
  url[SONOS_ART_URL_LEN - 1] = '\0';
  TEST_ASSERT_EQUAL_UINT(96, strlen(url));

  char json[256];
  int n = snprintf(json, sizeof(json), "{\"sart\":{\"gen\":4294967295,\"url\":\"%s\"},\"v\":1}", url);
  TEST_ASSERT_TRUE(n > 0 && (size_t)n < sizeof(json));
  // +1 for the '\n' the framer appends on the wire (hub_reassembler strips it before handing the parser
  // the frame, so it is not part of `json` itself, but IS part of the 139 B design ceiling).
  TEST_ASSERT_EQUAL_UINT((size_t)139, strlen(json) + 1);
  TEST_ASSERT_TRUE((size_t)139 < HUB_FRAME_MAX);   // the assertion belongs in the test, not a comment

  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(json, strlen(json), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT32(4294967295u, out.gen);
  TEST_ASSERT_TRUE(out.has_url);
  TEST_ASSERT_EQUAL_STRING(url, out.url);
}

// Over-cap url (97+ chars on the wire): REJECTED, not truncated. A truncated URL would be a
// guaranteed-failing fetch that looks like a network fault instead of a protocol violation.
static void test_sart_rejects_over_cap_url(void) {
  char url[SONOS_ART_URL_LEN + 1]; // 97 chars + NUL == exactly one over the 96-char cap
  memset(url, 'a', SONOS_ART_URL_LEN);
  url[SONOS_ART_URL_LEN] = '\0';
  TEST_ASSERT_EQUAL_UINT(97, strlen(url));

  char json[256];
  snprintf(json, sizeof(json), "{\"sart\":{\"gen\":1,\"url\":\"%s\"},\"v\":1}", url);

  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;   // pre-seed non-default so we can prove the parser set it to false
  TEST_ASSERT_FALSE(hub_parse_sart(json, strlen(json), &out, &had));
  TEST_ASSERT_FALSE(had);
}

// A 96-char url (exactly at the cap) must NOT be rejected -- the boundary is inclusive.
static void test_sart_accepts_url_exactly_at_cap(void) {
  char url[SONOS_ART_URL_LEN];
  memset(url, 'b', SONOS_ART_URL_LEN - 1);
  url[SONOS_ART_URL_LEN - 1] = '\0';
  TEST_ASSERT_EQUAL_UINT(96, strlen(url));

  char json[256];
  snprintf(json, sizeof(json), "{\"sart\":{\"gen\":1,\"url\":\"%s\"},\"v\":1}", url);

  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(json, strlen(json), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING(url, out.url);
}

// ===================== hub_parse_sart: S2 (no art this track) =====================

static void test_sart_parses_s2_no_url(void) {
  const char* j = "{\"v\":1,\"sart\":{\"gen\":8}}";
  hub_sart_t out; memset(&out, 0, sizeof(out));
  strncpy(out.url, "stale", sizeof(out.url));   // prove the parser clears rather than leaves stale data
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(j, strlen(j), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT32(8, out.gen);
  TEST_ASSERT_FALSE(out.has_url);
  TEST_ASSERT_EQUAL_STRING("", out.url);
}

// S2 at the cap: gen = UINT32_MAX. Design §2.3: exactly 34 bytes on the wire (incl. trailing '\n').
static void test_sart_s2_at_cap_is_34_bytes(void) {
  const char* json = "{\"sart\":{\"gen\":4294967295},\"v\":1}";
  TEST_ASSERT_EQUAL_UINT((size_t)34, strlen(json) + 1);   // +1 for the wire '\n'

  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(json, strlen(json), &out, &had));
  TEST_ASSERT_EQUAL_UINT32(4294967295u, out.gen);
  TEST_ASSERT_FALSE(out.has_url);
}

// ===================== hub_parse_sart: malformed / rejection =====================

static void test_sart_rejects_missing_gen(void) {
  const char* j = "{\"v\":1,\"sart\":{\"url\":\"http://1.2.3.4:1/a/x\"}}";
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sart(j, strlen(j), &out, &had));
  TEST_ASSERT_FALSE(had);
}

static void test_sart_rejects_malformed_json(void) {
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sart("not json", 8, &out, &had));
  TEST_ASSERT_FALSE(had);
}

static void test_sart_rejects_wrong_version(void) {
  const char* j = "{\"v\":2,\"sart\":{\"gen\":1}}";
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sart(j, strlen(j), &out, &had));
  TEST_ASSERT_FALSE(had);
}

static void test_sart_rejects_missing_sart_block(void) {
  const char* j = "{\"v\":1,\"usage\":{}}";
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sart(j, strlen(j), &out, &had));
  TEST_ASSERT_FALSE(had);
}

static void test_sart_rejects_non_object_sart_block(void) {
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = true;
  const char* jnull = "{\"v\":1,\"sart\":null}";
  TEST_ASSERT_FALSE(hub_parse_sart(jnull, strlen(jnull), &out, &had));
  TEST_ASSERT_FALSE(had);
  had = true;
  const char* jarr = "{\"v\":1,\"sart\":[1,2,3]}";
  TEST_ASSERT_FALSE(hub_parse_sart(jarr, strlen(jarr), &out, &had));
  TEST_ASSERT_FALSE(had);
}

// Unknown keys inside "sart" must be ignored, not reject the whole frame -- lets an older device stay
// usable against a hub that later widens this frame (additive v:1 extension, same rule as "sonos").
static void test_sart_ignores_unknown_keys(void) {
  const char* j = "{\"v\":1,\"sart\":{\"gen\":3,\"url\":\"http://1.2.3.4:1/a/x\",\"w\":200,\"h\":200,\"digest\":\"ab\"}}";
  hub_sart_t out; memset(&out, 0, sizeof(out));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sart(j, strlen(j), &out, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_UINT32(3, out.gen);
  TEST_ASSERT_EQUAL_STRING("http://1.2.3.4:1/a/x", out.url);
}

// ===================== hub_build_sart_stat (S3) =====================

static void test_sart_stat_ok_shape(void) {
  char buf[96];
  size_t n = hub_build_sart_stat(buf, sizeof(buf), 7, true, nullptr);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL_CHAR('\n', buf[n - 1]);
  JsonDocument doc;
  TEST_ASSERT_FALSE(deserializeJson(doc, buf));
  TEST_ASSERT_EQUAL_INT(1, doc["v"].as<int>());
  TEST_ASSERT_EQUAL_STRING("sart_stat", doc["cmd"].as<const char*>());
  TEST_ASSERT_EQUAL_UINT32(7, doc["gen"].as<uint32_t>());
  TEST_ASSERT_TRUE(doc["ok"].as<bool>());
  TEST_ASSERT_TRUE(doc["err"].isNull());
}

// S3 at the cap: gen = UINT32_MAX, err = "conn_refused" (the longest value in the frozen 6-value
// vocabulary). Design §2.3: exactly 75 bytes on the wire (incl. trailing '\n').
static void test_sart_stat_err_at_cap_is_75_bytes(void) {
  char buf[96];
  size_t n = hub_build_sart_stat(buf, sizeof(buf), 4294967295u, false, "conn_refused");
  TEST_ASSERT_EQUAL_UINT((size_t)75, n);
  TEST_ASSERT_EQUAL_CHAR('\n', buf[n - 1]);

  JsonDocument doc;
  TEST_ASSERT_FALSE(deserializeJson(doc, buf, n));
  TEST_ASSERT_EQUAL_UINT32(4294967295u, doc["gen"].as<uint32_t>());
  TEST_ASSERT_FALSE(doc["ok"].as<bool>());
  TEST_ASSERT_EQUAL_STRING("conn_refused", doc["err"].as<const char*>());
}

// timeout and conn_refused must never collapse into one value -- they are the evidence a later
// workstream's Local Network row consumes (design §2.3), so a caller passing either must see it verbatim.
static void test_sart_stat_timeout_and_conn_refused_are_distinct(void) {
  char a[96], b[96];
  size_t na = hub_build_sart_stat(a, sizeof(a), 1, false, "timeout");
  size_t nb = hub_build_sart_stat(b, sizeof(b), 1, false, "conn_refused");
  TEST_ASSERT_TRUE(na > 0 && nb > 0);
  TEST_ASSERT_TRUE(strstr(a, "\"err\":\"timeout\"") != nullptr);
  TEST_ASSERT_TRUE(strstr(b, "\"err\":\"conn_refused\"") != nullptr);
  TEST_ASSERT_TRUE(strcmp(a, b) != 0);
}

// A null/empty err on a failure falls back to "net" rather than emitting a malformed/empty err string.
static void test_sart_stat_null_err_falls_back_to_net(void) {
  char buf[96];
  size_t n = hub_build_sart_stat(buf, sizeof(buf), 1, false, nullptr);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_TRUE(strstr(buf, "\"err\":\"net\"") != nullptr);
}

static void test_sart_stat_rejects_invalid_args(void) {
  char buf[96];
  TEST_ASSERT_EQUAL_UINT(0, hub_build_sart_stat(nullptr, sizeof(buf), 1, true, nullptr));
  TEST_ASSERT_EQUAL_UINT(0, hub_build_sart_stat(buf, 0, 1, true, nullptr));
}

// ===================== hub_build_device_report (D-1) =====================

static void test_device_report_with_ip_shape(void) {
  char buf[96];
  size_t n = hub_build_device_report(buf, sizeof(buf), "192.168.1.42");
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_EQUAL_CHAR('\n', buf[n - 1]);
  JsonDocument doc;
  TEST_ASSERT_FALSE(deserializeJson(doc, buf));
  TEST_ASSERT_EQUAL_INT(1, doc["v"].as<int>());
  TEST_ASSERT_EQUAL_STRING("report", doc["cmd"].as<const char*>());
  TEST_ASSERT_EQUAL_STRING("device", doc["what"].as<const char*>());
  TEST_ASSERT_EQUAL_STRING("192.168.1.42", doc["ip"].as<const char*>());
}

// WiFi down: the "ip" key is OMITTED entirely, never an empty string (D-1) -- an empty string would let
// the hub attempt to build a URL to nowhere instead of treating the device as unreachable.
static void test_device_report_omits_ip_key_when_null(void) {
  char buf[96];
  size_t n = hub_build_device_report(buf, sizeof(buf), nullptr);
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_TRUE(strstr(buf, "\"ip\"") == nullptr);
  JsonDocument doc;
  TEST_ASSERT_FALSE(deserializeJson(doc, buf));
  TEST_ASSERT_EQUAL_STRING("device", doc["what"].as<const char*>());
  TEST_ASSERT_TRUE(doc["ip"].isNull());
}

static void test_device_report_omits_ip_key_when_empty_string(void) {
  char buf[96];
  size_t n = hub_build_device_report(buf, sizeof(buf), "");
  TEST_ASSERT_TRUE(n > 0);
  TEST_ASSERT_TRUE(strstr(buf, "\"ip\"") == nullptr);
}

static void test_device_report_rejects_invalid_args(void) {
  char buf[96];
  TEST_ASSERT_EQUAL_UINT(0, hub_build_device_report(nullptr, sizeof(buf), "1.2.3.4"));
  TEST_ASSERT_EQUAL_UINT(0, hub_build_device_report(buf, 0, "1.2.3.4"));
}

// ===================== back-compat (design §2.4) =====================

// (a) A "sart" frame handed to hub_parse_status: valid v:1 JSON with neither "usage" nor "buddy", so it
// is ACCEPTED (returns true, same as today's loc-only-frame precedent in test_hub_proto) but FILLS
// NOTHING -- both had_usage/had_buddy stay false. This is the actual, verified behavior of
// hub_parse_status for any frame it doesn't recognize (sessions/sdetail/sonos/comps/pages all land the
// same way via on_frame's dispatch-then-fallthrough); it does NOT return false.
static void test_backcompat_sart_frame_to_hub_parse_status_fills_nothing(void) {
  usage_rec_t u; buddy_rec_t b; bool hu = true, hb = true;
  memset(&u, 0, sizeof(u)); memset(&b, 0, sizeof(b));
  TEST_ASSERT_TRUE(hub_parse_status(S1_FULL, strlen(S1_FULL), &u, &hu, &b, &hb));
  TEST_ASSERT_FALSE(hu);
  TEST_ASSERT_FALSE(hb);
}

// (b) DeviceCommand.parse-equivalent on the firmware side: hub_parse_ack must not mistake a "sart_stat"
// (or any other unrecognized) frame for an ack/err -- it has neither an "ack" nor an "err" top-level key.
static void test_backcompat_sart_stat_is_not_mistaken_for_an_ack(void) {
  hub_ack_t ack;
  const char* j = "{\"v\":1,\"cmd\":\"sart_stat\",\"gen\":7,\"ok\":true}";
  TEST_ASSERT_FALSE(hub_parse_ack(j, strlen(j), &ack));
}

// A "sart" frame must not be mistaken for a "sonos" frame -- the two are structurally distinct blocks.
static void test_sart_frame_is_not_a_sonos_frame(void) {
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sonos(S1_FULL, strlen(S1_FULL), &s, &had));
  TEST_ASSERT_FALSE(had);
}

// ===================== DataStore wiring (the four accessors) =====================

static void test_art_datastore_defaults_to_no_art(void) {
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(0, r.gen);
  TEST_ASSERT_EQUAL_UINT32(0, r.seen_gen);
  TEST_ASSERT_EQUAL_UINT8(0, r.idx);
  TEST_ASSERT_FALSE(r.have);
}

static void test_art_publish_and_get_roundtrip(void) {
  ds_publish_sonos_art(5, 1);
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(5, r.gen);
  TEST_ASSERT_EQUAL_UINT8(1, r.idx);
  TEST_ASSERT_TRUE(r.have);
  TEST_ASSERT_EQUAL_UINT32(0, r.seen_gen);   // untouched by publish
}

static void test_art_seen_updates_only_seen_gen(void) {
  ds_publish_sonos_art(5, 1);
  ds_sonos_art_seen(5);
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(5, r.gen);
  TEST_ASSERT_EQUAL_UINT32(5, r.seen_gen);
  TEST_ASSERT_EQUAL_UINT8(1, r.idx);
  TEST_ASSERT_TRUE(r.have);
}

// S2: ds_clear_sonos_art() sets ONLY have=false; gen/idx/seen_gen are left exactly as they were
// ("bumps nothing else").
static void test_art_clear_touches_only_have(void) {
  ds_publish_sonos_art(9, 0);
  ds_sonos_art_seen(9);
  ds_clear_sonos_art();
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_FALSE(r.have);
  TEST_ASSERT_EQUAL_UINT32(9, r.gen);
  TEST_ASSERT_EQUAL_UINT32(9, r.seen_gen);
  TEST_ASSERT_EQUAL_UINT8(0, r.idx);
}

// D-2: gen is an IDENTITY, not an ordering. seen_gen=7 (already acked), then a NEW publish with gen=1 --
// numerically SMALLER, as happens after a hub relaunch resets its in-memory counter -- must be accepted
// verbatim by the DataStore (no clamping, no rejection). The device's own repoint rule (`gen !=
// seen_gen`, WS-2) then correctly reads this as "needs repoint" even though gen decreased, which a `>`
// comparison would have missed forever.
static void test_art_gen_is_identity_not_ordering(void) {
  ds_publish_sonos_art(7, 0);
  ds_sonos_art_seen(7);
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(7, r.gen);
  TEST_ASSERT_EQUAL_UINT32(7, r.seen_gen);

  ds_publish_sonos_art(1, 1);   // hub relaunch: numerically smaller gen
  r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(1, r.gen);          // accepted verbatim, even though 1 < the previous gen (7)
  TEST_ASSERT_EQUAL_UINT32(7, r.seen_gen);     // untouched by publish
  TEST_ASSERT_TRUE(r.gen != r.seen_gen);       // `!=` correctly flags "needs repoint" despite gen decreasing
}

// ===================== absence never clears (D-3's regression test) =====================
// The single most valuable test in this workstream: a "sonos" text frame arriving after a "sart" frame
// must leave sonos_art_rec_t COMPLETELY untouched. sonos_art_rec_t is a separate record from sonos_rec_t
// precisely so that hub_parse_sonos's full-snapshot semantics (every call fills *out fresh, zeroing
// absent fields) can never reach the art state.
static void test_art_survives_an_unrelated_sonos_frame(void) {
  ds_publish_sonos_art(5, 1);
  ds_sonos_art_seen(5);
  sonos_art_rec_t before = ds_get_sonos_art();
  TEST_ASSERT_TRUE(before.have);

  // A completely ordinary "sonos" now-playing heartbeat, applied exactly as hub_task.cpp's on_frame does
  // (parse into a fresh stack struct, then ds_set_sonos).
  const char* j = "{\"v\":1,\"sonos\":{\"room\":\"Kitchen\",\"track\":\"Black Hole Sun\","
                  "\"artist\":\"Soundgarden\",\"album\":\"Superunknown\",\"playing\":true}}";
  sonos_rec_t sn; memset(&sn, 0, sizeof(sn));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &sn, &had));
  TEST_ASSERT_TRUE(had);
  ds_set_sonos(&sn);

  sonos_art_rec_t after = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(before.gen, after.gen);
  TEST_ASSERT_EQUAL_UINT32(before.seen_gen, after.seen_gen);
  TEST_ASSERT_EQUAL_UINT8(before.idx, after.idx);
  TEST_ASSERT_TRUE(after.have);

  // And the reverse must also hold: applying art must never touch the (separately fetched) sonos text.
  sonos_rec_t sn2 = ds_get_sonos();
  TEST_ASSERT_EQUAL_STRING("Kitchen", sn2.room);
  TEST_ASSERT_EQUAL_STRING("Black Hole Sun", sn2.track);
}

// Even ds_set_hub_offline() (which flips usage/buddy/sonos to ST_HUB_OFFLINE on a dropped BLE link)
// must not touch sonos_art_rec_t -- it has no hdr/state at all; visibility (e.g. dimming) is derived by
// the view from ds_get_sonos().hdr.state, not from the art record itself.
static void test_art_survives_hub_offline_flip(void) {
  ds_publish_sonos_art(3, 0);
  ds_set_hub_offline();
  sonos_art_rec_t r = ds_get_sonos_art();
  TEST_ASSERT_EQUAL_UINT32(3, r.gen);
  TEST_ASSERT_TRUE(r.have);
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_sart_parses_s1_full_frame);
  RUN_TEST(test_sart_byte_exact_round_trip_matches_swift_fixture);
  RUN_TEST(test_sart_s1_at_cap_is_139_bytes_and_parses);
  RUN_TEST(test_sart_rejects_over_cap_url);
  RUN_TEST(test_sart_accepts_url_exactly_at_cap);
  RUN_TEST(test_sart_parses_s2_no_url);
  RUN_TEST(test_sart_s2_at_cap_is_34_bytes);
  RUN_TEST(test_sart_rejects_missing_gen);
  RUN_TEST(test_sart_rejects_malformed_json);
  RUN_TEST(test_sart_rejects_wrong_version);
  RUN_TEST(test_sart_rejects_missing_sart_block);
  RUN_TEST(test_sart_rejects_non_object_sart_block);
  RUN_TEST(test_sart_ignores_unknown_keys);
  RUN_TEST(test_sart_stat_ok_shape);
  RUN_TEST(test_sart_stat_err_at_cap_is_75_bytes);
  RUN_TEST(test_sart_stat_timeout_and_conn_refused_are_distinct);
  RUN_TEST(test_sart_stat_null_err_falls_back_to_net);
  RUN_TEST(test_sart_stat_rejects_invalid_args);
  RUN_TEST(test_device_report_with_ip_shape);
  RUN_TEST(test_device_report_omits_ip_key_when_null);
  RUN_TEST(test_device_report_omits_ip_key_when_empty_string);
  RUN_TEST(test_device_report_rejects_invalid_args);
  RUN_TEST(test_backcompat_sart_frame_to_hub_parse_status_fills_nothing);
  RUN_TEST(test_backcompat_sart_stat_is_not_mistaken_for_an_ack);
  RUN_TEST(test_sart_frame_is_not_a_sonos_frame);
  RUN_TEST(test_art_datastore_defaults_to_no_art);
  RUN_TEST(test_art_publish_and_get_roundtrip);
  RUN_TEST(test_art_seen_updates_only_seen_gen);
  RUN_TEST(test_art_clear_touches_only_have);
  RUN_TEST(test_art_gen_is_identity_not_ordering);
  RUN_TEST(test_art_survives_an_unrelated_sonos_frame);
  RUN_TEST(test_art_survives_hub_offline_flip);
  return UNITY_END();
}
