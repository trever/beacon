#include <unity.h>
#include <stdio.h>
#include <string.h>
#include "core/hub_proto.h"
#include "core/datastore.h"
#include "core/stale.h"
#include "config/ticker_table.h"

// datastore_init() seeds finance from the runtime ticker table (#92); ticker_table_init() seeds that
// table from DEFAULT_TICKERS on the native build. Mirrors test_datastore's setUp.
void setUp(void) { ticker_table_init(); datastore_init(); }
void tearDown(void) {}

// ===================== hub_parse_sonos =====================

static const char* FULL =
  "{\"v\":1,\"sonos\":{\"room\":\"Kitchen\",\"track\":\"Black Hole Sun\",\"artist\":\"Soundgarden\","
  "\"album\":\"Superunknown\",\"playing\":true}}";

static void test_sonos_parses_full_frame(void) {
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(FULL, strlen(FULL), &s, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("Kitchen", s.room);
  TEST_ASSERT_EQUAL_STRING("Black Hole Sun", s.track);
  TEST_ASSERT_EQUAL_STRING("Soundgarden", s.artist);
  TEST_ASSERT_EQUAL_STRING("Superunknown", s.album);
  TEST_ASSERT_TRUE(s.playing);
}

static void test_sonos_playing_false(void) {
  const char* j = "{\"v\":1,\"sonos\":{\"room\":\"Office\",\"track\":\"t\",\"artist\":\"a\","
                  "\"album\":\"b\",\"playing\":false}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_FALSE(s.playing);
}

// Spec: absent fields are OMITTED, not null; a missing "playing" means false. Every string field
// defaults to empty, independent of one another.
static void test_sonos_missing_fields_default_to_empty_and_false(void) {
  const char* j = "{\"v\":1,\"sonos\":{\"room\":\"Kitchen\"}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("Kitchen", s.room);
  TEST_ASSERT_EQUAL_STRING("", s.track);
  TEST_ASSERT_EQUAL_STRING("", s.artist);
  TEST_ASSERT_EQUAL_STRING("", s.album);
  TEST_ASSERT_FALSE(s.playing);
}

// An entirely empty "sonos" object is legal (e.g. nothing playing in the room) -- everything defaults.
static void test_sonos_empty_object_defaults_everything(void) {
  const char* j = "{\"v\":1,\"sonos\":{}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("", s.room);
  TEST_ASSERT_EQUAL_STRING("", s.track);
  TEST_ASSERT_FALSE(s.playing);
}

// Full snapshot, NOT sticky per-field like "sdetail": a second frame that omits fields the first frame
// set must CLEAR them, not preserve the caller's prior struct contents.
static void test_sonos_not_sticky_across_frames(void) {
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(FULL, strlen(FULL), &s, &had));
  TEST_ASSERT_EQUAL_STRING("Black Hole Sun", s.track);

  const char* next = "{\"v\":1,\"sonos\":{\"room\":\"Kitchen\"}}";
  TEST_ASSERT_TRUE(hub_parse_sonos(next, strlen(next), &s, &had));
  TEST_ASSERT_EQUAL_STRING("Kitchen", s.room);
  TEST_ASSERT_EQUAL_STRING("", s.track);     // cleared, not held over from the previous frame
  TEST_ASSERT_EQUAL_STRING("", s.artist);
  TEST_ASSERT_EQUAL_STRING("", s.album);
  TEST_ASSERT_FALSE(s.playing);
}

// Over-length strings: the hub is documented to cap room<=20/track<=40/artist<=32/album<=32, but the
// device parser must be defensive regardless (never overflow, always NUL-terminate at *_LEN-1).
static void test_sonos_truncates_overlong_strings(void) {
  char room[64], track[128], artist[96], album[96];
  memset(room, 'R', sizeof(room) - 1);   room[sizeof(room) - 1] = '\0';
  memset(track, 'T', sizeof(track) - 1); track[sizeof(track) - 1] = '\0';
  memset(artist, 'A', sizeof(artist) - 1); artist[sizeof(artist) - 1] = '\0';
  memset(album, 'B', sizeof(album) - 1);   album[sizeof(album) - 1] = '\0';

  char j[512];
  snprintf(j, sizeof(j), "{\"v\":1,\"sonos\":{\"room\":\"%s\",\"track\":\"%s\",\"artist\":\"%s\","
           "\"album\":\"%s\",\"playing\":true}}", room, track, artist, album);

  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_EQUAL_UINT(SONOS_ROOM_LEN - 1,   strlen(s.room));
  TEST_ASSERT_EQUAL_UINT(SONOS_TRACK_LEN - 1,  strlen(s.track));
  TEST_ASSERT_EQUAL_UINT(SONOS_ARTIST_LEN - 1, strlen(s.artist));
  TEST_ASSERT_EQUAL_UINT(SONOS_ALBUM_LEN - 1,  strlen(s.album));
}

// Unknown keys inside the "sonos" block must be ignored, not reject the whole frame -- this is what
// lets an older firmware stay usable against a hub that later adds fields (additive v:1 extension).
static void test_sonos_ignores_unknown_keys(void) {
  const char* j = "{\"v\":1,\"sonos\":{\"room\":\"Kitchen\",\"track\":\"Song\",\"art_url\":\"http://x\","
                  "\"duration_ms\":123456,\"playing\":true,\"queue\":[1,2,3]}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = false;
  TEST_ASSERT_TRUE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_TRUE(had);
  TEST_ASSERT_EQUAL_STRING("Kitchen", s.room);
  TEST_ASSERT_EQUAL_STRING("Song", s.track);
  TEST_ASSERT_TRUE(s.playing);
}

static void test_sonos_rejects_malformed_json(void) {
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sonos("not json", 8, &s, &had));
  TEST_ASSERT_FALSE(had);
  const char* truncated = "{\"v\":1,\"sonos\":{\"room\":\"Kitc";
  had = true;
  TEST_ASSERT_FALSE(hub_parse_sonos(truncated, strlen(truncated), &s, &had));
  TEST_ASSERT_FALSE(had);
}

static void test_sonos_rejects_wrong_version(void) {
  const char* j = "{\"v\":2,\"sonos\":{\"room\":\"Kitchen\"}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_FALSE(had);
}

// No "sonos" key at all -- e.g. this is a "usage"/"buddy" status frame or a "sessions" frame. Must not
// be mistaken for an empty/valid sonos block.
static void test_sonos_rejects_missing_sonos_block(void) {
  const char* j = "{\"v\":1,\"usage\":{\"providers\":[]}}";
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = true;
  TEST_ASSERT_FALSE(hub_parse_sonos(j, strlen(j), &s, &had));
  TEST_ASSERT_FALSE(had);
}

// "sonos" present but not an object (null / scalar) must also be rejected, not treated as empty.
static void test_sonos_rejects_non_object_sonos_block(void) {
  sonos_rec_t s; memset(&s, 0, sizeof(s));
  bool had = true;
  const char* jnull = "{\"v\":1,\"sonos\":null}";
  TEST_ASSERT_FALSE(hub_parse_sonos(jnull, strlen(jnull), &s, &had));
  TEST_ASSERT_FALSE(had);
  had = true;
  const char* jstr = "{\"v\":1,\"sonos\":\"kitchen\"}";
  TEST_ASSERT_FALSE(hub_parse_sonos(jstr, strlen(jstr), &s, &had));
  TEST_ASSERT_FALSE(had);
  had = true;
  const char* jarr = "{\"v\":1,\"sonos\":[1,2,3]}";
  TEST_ASSERT_FALSE(hub_parse_sonos(jarr, strlen(jarr), &s, &had));
  TEST_ASSERT_FALSE(had);
}

// ===================== DataStore wiring =====================
// Sonos follows the usage/buddy hub-plane idiom: setter forces LIVE, staleness sweep promotes to
// STALE, ds_set_hub_offline() flips it, and the state-priority rule (screen_state.h) still holds.

static void test_sonos_datastore_roundtrip_forces_live(void) {
  sonos_rec_t r; memset(&r, 0, sizeof(r));
  strncpy(r.room, "Kitchen", SONOS_ROOM_LEN - 1);
  strncpy(r.track, "Song", SONOS_TRACK_LEN - 1);
  r.playing = true;
  r.hdr.last_updated = 1000; r.hdr.state = ST_ERROR;   // setter must override to LIVE
  ds_set_sonos(&r);
  sonos_rec_t g = ds_get_sonos();
  TEST_ASSERT_EQUAL_STRING("Kitchen", g.room);
  TEST_ASSERT_EQUAL_STRING("Song", g.track);
  TEST_ASSERT_TRUE(g.playing);
  TEST_ASSERT_EQUAL_INT(ST_LIVE, g.hdr.state);
  TEST_ASSERT_EQUAL_INT(ERR_NONE, g.hdr.err);
}

static void test_sonos_staleness_inclusive_boundary(void) {
  sonos_rec_t r; memset(&r, 0, sizeof(r)); r.hdr.last_updated = 1000;
  ds_set_sonos(&r);   // LIVE
  ds_tick_staleness(1000 + SONOS_STALE_S - 1);
  TEST_ASSERT_EQUAL_INT(ST_LIVE, ds_get_sonos().hdr.state);
  ds_tick_staleness(1000 + SONOS_STALE_S);          // inclusive boundary
  TEST_ASSERT_EQUAL_INT(ST_STALE, ds_get_sonos().hdr.state);
}

static void test_sonos_hub_offline_flip_and_recovery(void) {
  ds_set_hub_offline();
  TEST_ASSERT_EQUAL_INT(ST_HUB_OFFLINE, ds_get_sonos().hdr.state);
  sonos_rec_t r; memset(&r, 0, sizeof(r)); r.hdr.last_updated = 1000;
  strncpy(r.room, "Kitchen", SONOS_ROOM_LEN - 1);
  ds_set_sonos(&r);
  TEST_ASSERT_EQUAL_INT(ST_LIVE, ds_get_sonos().hdr.state);   // recovered on the next live push
}

static void test_sonos_sweep_never_clobbers_explicit_states(void) {
  ds_set_state_sonos(ST_ERROR, ERR_RATE_LIMITED);
  ds_tick_staleness(9999999);
  TEST_ASSERT_EQUAL_INT(ST_ERROR, ds_get_sonos().hdr.state);   // not promoted to STALE
}

int main(int, char**) {
  UNITY_BEGIN();
  RUN_TEST(test_sonos_parses_full_frame);
  RUN_TEST(test_sonos_playing_false);
  RUN_TEST(test_sonos_missing_fields_default_to_empty_and_false);
  RUN_TEST(test_sonos_empty_object_defaults_everything);
  RUN_TEST(test_sonos_not_sticky_across_frames);
  RUN_TEST(test_sonos_truncates_overlong_strings);
  RUN_TEST(test_sonos_ignores_unknown_keys);
  RUN_TEST(test_sonos_rejects_malformed_json);
  RUN_TEST(test_sonos_rejects_wrong_version);
  RUN_TEST(test_sonos_rejects_missing_sonos_block);
  RUN_TEST(test_sonos_rejects_non_object_sonos_block);
  RUN_TEST(test_sonos_datastore_roundtrip_forces_live);
  RUN_TEST(test_sonos_staleness_inclusive_boundary);
  RUN_TEST(test_sonos_hub_offline_flip_and_recovery);
  RUN_TEST(test_sonos_sweep_never_clobbers_explicit_states);
  return UNITY_END();
}
