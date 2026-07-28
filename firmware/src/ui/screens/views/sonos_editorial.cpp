// Sonos now-playing -- two-form screen (album art design doc §3.2/§3.3; plan §4 WS-3). The masthead
// (eyebrow + status slot, room, play state, hairline) is byte-identical between forms so the switch
// reads as quiet rather than a jump; below the hairline the screen is either the ART form (a 200x200
// tile + track/artist) or the NO-ART form (phase 1's shipped track/artist/album, verbatim). Both are
// built in build() as two containers; update() only toggles LV_OBJ_FLAG_HIDDEN and text/values --
// CONVENTIONS.md's "build() creates, update() is read-only w.r.t. layout" applies to the whole file.
#include "ui/screen.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/theme.h"
#include "config/layout.h"
#include "core/datastore.h"
#include "core/sonos_art.h"   // tile buffers live in core (WS-2); this view only reads them
#include "util/log.h"
#include <esp_heap_caps.h>
#include <ctype.h>

// ---------------------------------------------------------------------------------------------------
// D-9: the tile buffers are allocated in THIS screen's build(), and nowhere else. If "sonos" is not in
// the active page list, build() never runs, not one byte is allocated, and a stray `sart` frame is
// dropped silently rather than fetched. The buffers themselves belong to core/sonos_art.cpp, reached
// through sonos_art_alloc()/sonos_art_buf() -- so the fetch task writes the very buffer this view
// reads, and there is exactly one 160 KB PSRAM allocation in the tree. WS-3 built against a local
// stand-in because WS-2's file was not visible in its worktree; that stand-in was removed when wave B
// merged. Do not reintroduce a view-local allocation: two allocations would double the PSRAM cost and
// the tile would render whichever one the fetch task did not fill.
static bool s_tile_ready = false;   // sonos_art_alloc() succeeded

static lv_obj_t *s_slot, *s_room, *s_rule, *s_state;
static lv_obj_t *s_form_noart, *s_track, *s_artist, *s_album;
static lv_obj_t *s_form_art, *s_tile, *s_track_art, *s_artist_art;
static lv_img_dsc_t s_tile_dsc;   // file-static: LVGL stores this pointer, never copies it (CONVENTIONS trap)

// Diff-aware image-opacity setter, same idiom as screen_common.h's bg_opa_if/txt_color.
static void img_opa_if(lv_obj_t* o, lv_opa_t a) {
  if (lv_obj_get_style_img_opa(o, LV_PART_MAIN) != a) lv_obj_set_style_img_opa(o, a, 0);
}

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();
  s_slot = build_header(page, "SONOS");

  // --- Masthead: shared byte-for-byte by both forms (design §3.2's stated goal) ---
  s_room = lv_label_create(page);
  lv_obj_set_style_text_font(s_room, t->f_mono, 0);
  lv_obj_set_style_text_color(s_room, t->accent, 0);
  lv_obj_set_style_text_letter_space(s_room, 2, 0);
  lv_label_set_text(s_room, "--");
  lv_obj_align(s_room, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 34);

  // Play state moves here from the old bottom-left corner (design §3.2 change 1): right-aligned
  // opposite the room, ending at x=426=466-40 (DESIGN.md's edge-row inset rule).
  s_state = lv_label_create(page);
  lv_obj_set_style_text_font(s_state, t->f_mono, 0);
  lv_obj_set_style_text_letter_space(s_state, 2, 0);
  lv_label_set_text(s_state, "");
  lv_obj_align(s_state, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET + 34);

  s_rule = lv_obj_create(page);
  lv_obj_remove_style_all(s_rule);
  lv_obj_add_style(s_rule, &S.hairline, 0);
  lv_obj_set_size(s_rule, SCREEN_W - 2 * SAFE_INSET, 1);
  lv_obj_align(s_rule, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 64);

  // --- No-art form: phase 1's shipped layout, verbatim (design §3.3) ---
  s_form_noart = lv_obj_create(page);
  lv_obj_remove_style_all(s_form_noart);
  lv_obj_set_size(s_form_noart, SCREEN_W, SCREEN_H);
  lv_obj_set_pos(s_form_noart, 0, 0);
  lv_obj_clear_flag(s_form_noart, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_clear_flag(s_form_noart, LV_OBJ_FLAG_CLICKABLE);

  s_track = lv_label_create(s_form_noart);
  lv_obj_add_style(s_track, &S.display, 0);
  lv_label_set_long_mode(s_track, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_track, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_track, "--");
  lv_obj_align(s_track, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 82);

  s_artist = lv_label_create(s_form_noart);
  lv_obj_add_style(s_artist, &S.body, 0);
  lv_label_set_long_mode(s_artist, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_artist, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_artist, "");
  lv_obj_align(s_artist, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 140);

  s_album = lv_label_create(s_form_noart);
  lv_obj_add_style(s_album, &S.slot, 0);
  lv_label_set_long_mode(s_album, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_album, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_album, "");
  lv_obj_align(s_album, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 176);

  // --- Art form: 200x200 tile + track/artist, no album line (design §3.2) ---
  s_form_art = lv_obj_create(page);
  lv_obj_remove_style_all(s_form_art);
  lv_obj_set_size(s_form_art, SCREEN_W, SCREEN_H);
  lv_obj_set_pos(s_form_art, 0, 0);
  lv_obj_clear_flag(s_form_art, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_clear_flag(s_form_art, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_add_flag(s_form_art, LV_OBJ_FLAG_HIDDEN);   // safe default; first update() sets the real state

  // D-9: buffers allocated here, on this screen's first build(), idempotent (on_theme() can rebuild).
  // Never freed (design §4.2 -- there is no steady-state allocation, so nothing to leak/fragment). If
  // "sonos" is not in the active page list this build() never runs and not one byte is allocated.
  if (!s_tile_ready) {
    s_tile_ready = sonos_art_alloc();
    if (!s_tile_ready) LOGE("sonos: tile buffer alloc failed (2x %u B)", (unsigned)SONOS_TILE_BYTES);
  }

  s_tile = lv_img_create(s_form_art);
  s_tile_dsc.header.always_zero = 0;
  s_tile_dsc.header.cf = LV_IMG_CF_TRUE_COLOR;   // LV_COLOR_16_SWAP=1 -> big-endian RGB565 (docs/perf.md
                                                  // §2.1); the hub already emits big-endian (Phase A).
                                                  // Do not byte-swap here.
  s_tile_dsc.header.w = SONOS_TILE_W;
  s_tile_dsc.header.h = SONOS_TILE_H;
  s_tile_dsc.data_size = SONOS_TILE_BYTES;
  s_tile_dsc.data = sonos_art_buf(0);   // placeholder until the first real repoint in update()
  lv_obj_set_size(s_tile, SONOS_TILE_W, SONOS_TILE_H);
  lv_obj_align(s_tile, LV_ALIGN_TOP_LEFT, 133, SAFE_INSET + 84);   // x 133..333 centred, y 124..324

  s_track_art = lv_label_create(s_form_art);
  lv_obj_add_style(s_track_art, &S.display, 0);
  lv_label_set_long_mode(s_track_art, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_track_art, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_track_art, "--");
  lv_obj_align(s_track_art, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 304);

  s_artist_art = lv_label_create(s_form_art);
  lv_obj_add_style(s_artist_art, &S.body, 0);
  lv_label_set_long_mode(s_artist_art, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_artist_art, SCREEN_W - 2 * SAFE_INSET);
  lv_label_set_text(s_artist_art, "");
  lv_obj_align(s_artist_art, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 350);
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
  sonos_art_rec_t art = ds_get_sonos_art();
  uint32_t now = now_s();
  slot_set(s_slot, "", &r.hdr, now);

  // No track yet (still loading, or the hub sent an empty "sonos" block) => placeholders, no play-state
  // claim, and ALWAYS the no-art form (design §3.3's no_track rule, unchanged from phase 1).
  bool no_track = sv_placeholder(r.hdr.state) || !r.track[0];
  bool dim = sv_dim(r.hdr.state);   // sonos only ever reaches LOADING/LIVE/HUB_OFFLINE; dim == hub-offline
                                     // in practice (design §8), but reuse the shared predicate like every
                                     // other view rather than special-case the state enum here.

  char room_up[SONOS_ROOM_LEN];
  upper_copy(room_up, sizeof(room_up), r.room[0] ? r.room : "--");
  txt_set(s_room, room_up);
  txt_color(s_room, dim ? t->ink_dim : t->accent);

  if (no_track) {
    txt_set(s_state, "");
  } else {
    txt_set(s_state, r.playing ? "PLAYING" : "PAUSED");
    txt_color(s_state, dim ? t->ink_dim : (r.playing ? t->accent : t->ink_dim));
  }

  // The tile repoint, per plan §4 WS-3's update() contract: `art.gen != art.seen_gen` is
  // sonos_art_should_repoint(gen, seen_gen) inlined (D-2: gen is an opaque identity, compared with !=,
  // never >). ds_sonos_art_seen() is the ack half of the cross-core swap protocol (plan §4 WS-2 rule 5)
  // -- Core 0 will not start writing the back buffer again until this lands or 3s elapse, so dropping
  // this call freezes art after the first tile. LOAD-BEARING; do not remove in a refactor.
  if (art.have && s_tile_ready && art.gen != art.seen_gen) {
    s_tile_dsc.data = sonos_art_buf(art.idx);
    lv_img_set_src(s_tile, &s_tile_dsc);
    lv_obj_invalidate(s_tile);
    ds_sonos_art_seen(art.gen);
  }

  bool show_art = !no_track && art.have;
  hidden_set(s_form_art,    !show_art);
  hidden_set(s_form_noart,   show_art);

  if (show_art) {
    txt_set(s_track_art,  r.track);
    txt_set(s_artist_art, r.artist);
    value_state(s_track_art, r.hdr.state);
    value_state(s_artist_art, r.hdr.state);
    // Hub-offline: keep showing the last tile, dimmed via opacity (design §8) -- not blanked, which
    // would falsely assert "nothing playing", and not recoloured, which costs an extra draw pass.
    img_opa_if(s_tile, dim ? LV_OPA_40 : LV_OPA_COVER);
  } else {
    txt_set(s_track,  no_track ? "--" : r.track);
    txt_set(s_artist, no_track ? "" : r.artist);
    txt_set(s_album,  no_track ? "" : r.album);
    value_state(s_track, r.hdr.state);
    value_state(s_artist, r.hdr.state);
    // s_album keeps its S.slot ink_dim baseline unconditionally, same as phase 1 shipped -- it was
    // never run through value_state() and this form doesn't start now.
  }
}

extern const screen_view_t sonos_editorial_view = { build, update };
