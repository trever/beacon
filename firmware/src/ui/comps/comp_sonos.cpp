// Home complication: Sonos now-playing (1 slot, owner "sonos", no arg -- the followed room lives in
// SonosRoomStore/SonosProvider.setSelectedRoom on the hub, never on the wire here; plan §1 item 1/§9.2).
// New content, shape B like agents: icon + track / "artist . room". There is no lucide glyph for
// music/audio in the compiled 12-codepoint subset (ui/fonts/icons.h, MANIFEST.md) -- ICON_ZAP is reused
// as a generic "now playing" cue rather than regenerating the font subset for this workstream (bench
// item, plan §10 item 4 / WS-4 return -- kept as-is, see WS-4's report on the flash cost of the
// alternative). build() is shared with comp_agents via comp_common.h (convergence sweep, plan §10 item
// 1): both are shape-B rows (icon + two lines).
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/fonts/icons.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "config/layout.h"
#include "core/datastore.h"

static lv_obj_t *s_icon, *s_line1, *s_line2;

static void build(lv_obj_t* slot) {
  comp_build_shape_b(slot, ICON_ZAP, &s_icon, &s_line1, &s_line2);
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  sonos_rec_t r = ds_get_sonos();

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &r.hdr, now_s())) {
    lv_obj_set_style_text_color(s_icon, sv_severe(r.hdr.state) ? t->down : t->ink_dim, 0);
    txt_set(s_line1, "sonos");
    txt_color(s_line1, t->ink_dim);
    txt_set(s_line2, sbuf);
    txt_color(s_line2, sv_severe(r.hdr.state) ? t->down : t->ink_dim);
    return;
  }

  lv_obj_set_style_text_color(s_icon, r.playing ? t->accent : t->ink_dim, 0);

  if (!r.track[0]) {
    // No track yet (loading, or the hub sent an empty "sonos" block -- nothing playing in the
    // selected room) -- placeholder, no play-state claim (mirrors sonos_editorial.cpp's `no_track`).
    txt_set(s_line1, "nothing playing");
    txt_color(s_line1, t->ink_dim);
    txt_set(s_line2, r.room[0] ? r.room : "");
    txt_color(s_line2, t->ink_dim);
    return;
  }

  txt_set(s_line1, r.track);
  txt_color(s_line1, t->ink);

  char l2[SONOS_ARTIST_LEN + SONOS_ROOM_LEN + 4];
  if (r.artist[0] && r.room[0]) snprintf(l2, sizeof(l2), "%s . %s", r.artist, r.room);
  else if (r.artist[0])         snprintf(l2, sizeof(l2), "%s", r.artist);
  else                          snprintf(l2, sizeof(l2), "%s", r.room);
  txt_set(s_line2, l2);
  txt_color(s_line2, t->ink_dim);
}

extern const complication_t comp_sonos_reg = { "sonos", "sonos", "Sonos", build, update };
