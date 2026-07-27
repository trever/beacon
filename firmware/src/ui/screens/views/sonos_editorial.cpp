// Sonos now-playing -- phase 1, text only (design doc §3; album art is a phase-2 hub-served-URL job,
// deliberately not attempted here). Editorial lane: masthead (room) over a hairline, then track/artist/
// album as a small type hierarchy (display/body/mono, biggest to smallest), play state pinned to the
// bottom-left corner the way buddy's action row sits.
#include "ui/screen.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/theme.h"
#include "config/layout.h"
#include "core/datastore.h"
#include <ctype.h>

static lv_obj_t *s_slot, *s_room, *s_rule, *s_track, *s_artist, *s_album, *s_state;

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();
  s_slot = build_header(page, "SONOS");

  // Room tag: mono + accent, editorial's masthead treatment (matches the eyebrow's own look) so the
  // selected room reads as a subheading rather than content.
  s_room = lv_label_create(page);
  lv_obj_set_style_text_font(s_room, t->f_mono, 0);
  lv_obj_set_style_text_color(s_room, t->accent, 0);
  lv_obj_set_style_text_letter_space(s_room, 2, 0);
  lv_label_set_text(s_room, "--");
  lv_obj_align(s_room, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 34);

  s_rule = lv_obj_create(page);
  lv_obj_remove_style_all(s_rule);
  lv_obj_add_style(s_rule, &S.hairline, 0);
  lv_obj_set_size(s_rule, SCREEN_W - 2 * SAFE_INSET, 1);
  lv_obj_align(s_rule, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 64);

  // Track: the biggest full-ASCII face available (f_display -- the hero subset has no letters,
  // fonts/MANIFEST.md). Single line with a dot ellipsis: the 40-char wire cap can still overrun 466px
  // at this size, and the codebase's convention is truncate-not-wrap for fixed-position labels.
  s_track = lv_label_create(page);
  lv_obj_add_style(s_track, &S.display, 0);
  lv_label_set_long_mode(s_track, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_track, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_track, "--");
  lv_obj_align(s_track, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 82);

  s_artist = lv_label_create(page);
  lv_obj_add_style(s_artist, &S.body, 0);
  lv_label_set_long_mode(s_artist, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_artist, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_artist, "");
  lv_obj_align(s_artist, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 140);

  s_album = lv_label_create(page);
  lv_obj_add_style(s_album, &S.slot, 0);
  lv_label_set_long_mode(s_album, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_album, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_album, "");
  lv_obj_align(s_album, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 176);

  // Play state, bottom-left -- mirrors buddy's approve/deny corner anchor (mk_btn) so every screen's
  // "the one thing that changes fastest" idiom lands in the same place.
  s_state = lv_label_create(page);
  lv_obj_set_style_text_font(s_state, t->f_mono, 0);
  lv_obj_set_style_text_letter_space(s_state, 2, 0);
  lv_label_set_text(s_state, "");
  lv_obj_align(s_state, LV_ALIGN_BOTTOM_LEFT, SAFE_INSET, -SAFE_INSET);
}

// Uppercase into a caller buffer (editorial casing convention, view_common.h's render_clock_ex does the
// same for the date). `src` is a *_LEN-capacity NUL-terminated record field, never NULL.
static void upper_copy(char* out, size_t n, const char* src) {
  size_t i = 0;
  for (; src[i] && i + 1 < n; i++) out[i] = (char)toupper((unsigned char)src[i]);
  out[i] = '\0';
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  sonos_rec_t r = ds_get_sonos();
  uint32_t now = now_s();
  slot_set(s_slot, "", &r.hdr, now);

  // No track yet (still loading, or the hub sent an empty "sonos" block -- nothing playing in the
  // selected room) => placeholders, and no play-state claim to make.
  bool no_track = sv_placeholder(r.hdr.state) || !r.track[0];

  char room_up[SONOS_ROOM_LEN];
  upper_copy(room_up, sizeof(room_up), r.room[0] ? r.room : "--");
  txt_set(s_room, room_up);
  txt_color(s_room, sv_dim(r.hdr.state) ? t->ink_dim : t->accent);

  txt_set(s_track,  no_track ? "--" : r.track);
  txt_set(s_artist, no_track ? "" : r.artist);
  txt_set(s_album,  no_track ? "" : r.album);
  value_state(s_track, r.hdr.state);
  value_state(s_artist, r.hdr.state);

  if (no_track) {
    txt_set(s_state, "");
  } else {
    txt_set(s_state, r.playing ? "PLAYING" : "PAUSED");
    txt_color(s_state, sv_dim(r.hdr.state) ? t->ink_dim : (r.playing ? t->accent : t->ink_dim));
  }
}

extern const screen_view_t sonos_editorial_view = { build, update };
