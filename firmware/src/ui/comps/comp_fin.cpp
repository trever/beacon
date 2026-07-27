// Home complication: one finance instrument (1 slot, owner "markets"), selected by `arg` (a ticker id).
// Verbatim body-move of home_editorial.cpp's market_row/market_put/finance_by_id (plan §4 items 1/3) --
// the S&P-specific call site is gone because comp_fin is now generic and one-instance-per-id: it renders
// whichever ticker the hub assigns via comp_arg("fin", ...), the same finance_by_id scan today's Home
// does. NEVER assume slot 0 (plan's registry table) -- the list is hub-editable.
#include "ui/comps/comp_registry.h"
#include "core/comp_state.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/fonts/icons.h"
#include "ui/fmt.h"
#include "ui/tick_flash.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"
#include <string.h>
#include <ctype.h>

static lv_obj_t *s_name, *s_val, *s_icon, *s_pct;
static tick_flash_t s_flash;

static void build(lv_obj_t* slot) {
  const beacon_theme_t* t = theme_active();

  s_name = lv_label_create(slot);
  lv_obj_add_style(s_name, &S.slot, 0);
  lv_label_set_text(s_name, "--");
  lv_obj_align(s_name, LV_ALIGN_TOP_LEFT, 0, 18);

  s_val = lv_label_create(slot);
  lv_obj_add_style(s_val, &S.display, 0);
  lv_label_set_text(s_val, "--");
  lv_obj_align(s_val, LV_ALIGN_TOP_RIGHT, 0, 10);

  // Percent and its trend glyph are separate labels: the glyph is a PUA codepoint that only renders
  // in a lucide face (ui/fonts/icons.h), so it cannot share a label with the number.
  s_pct = lv_label_create(slot);
  lv_obj_add_style(s_pct, &S.slot, 0);
  lv_label_set_text(s_pct, "");
  lv_obj_align(s_pct, LV_ALIGN_TOP_RIGHT, 0, 40);

  s_icon = lv_label_create(slot);
  lv_obj_set_style_text_font(s_icon, t->f_icon, 0);
  lv_obj_set_style_text_color(s_icon, t->ink_dim, 0);
  lv_label_set_text(s_icon, "");
  lv_obj_align_to(s_icon, s_pct, LV_ALIGN_OUT_LEFT_MID, -6, 0);
}

static void update(void) {
  const beacon_theme_t* t = theme_active();

  char arg[COMP_ARG_LEN];
  bool has_arg = comp_arg("fin", arg, sizeof(arg));

  int idx = -1;
  uint8_t n = has_arg ? ds_get_finance_count() : 0;
  finance_rec_t f;
  for (uint8_t i = 0; i < n; i++) {
    f = ds_get_finance(i);
    if (strncmp(f.id, arg, FIN_ID_LEN) == 0) { idx = i; break; }
  }

  if (idx < 0) {
    // Not configured (no arg), or the configured id isn't in the hub's current ticker list -- say so
    // instead of showing a stuck "--" (generalizes today's Home's sp500-specific "not in list" case to
    // any ticker id).
    char up[COMP_ARG_LEN]; size_t k = 0;
    for (; has_arg && arg[k] && k + 1 < sizeof(up); k++) up[k] = (char)toupper((unsigned char)arg[k]);
    up[k] = '\0';
    txt_set(s_name, has_arg ? up : "FIN");
    txt_set(s_val, "--");
    txt_set(s_pct, "not in list");
    txt_color(s_pct, t->ink_dim);
    lv_label_set_text(s_icon, "");
    return;
  }

  txt_set(s_name, fin_name(idx, f));

  bool live = (f.hdr.state == ST_LIVE);
  if (!live) tick_flash_reset(&s_flash);   // don't flash on the link merely coming back

  char v[32]; fmt_usd(v, sizeof(v), f.value);
  txt_set(s_val, sv_placeholder(f.hdr.state) ? "--" : v);
  lv_color_t resting = sv_dim(f.hdr.state) ? t->ink_dim : t->ink;
  txt_color(s_val, live ? tick_flash_color(&s_flash, f.value, t, resting) : resting);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &f.hdr, now_s())) {
    txt_set(s_pct, sbuf);
    txt_color(s_pct, sv_severe(f.hdr.state) ? t->down : t->ink_dim);
    lv_label_set_text(s_icon, "");   // no trend claim while the source is not live
    return;
  }
  char pb[16];
  int dir = fmt_change_num(pb, sizeof(pb), f.change_pct);
  txt_set(s_pct, pb);
  lv_color_t dc = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
  txt_color(s_pct, dc);
  lv_label_set_text(s_icon, dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
  lv_obj_set_style_text_color(s_icon, dc, 0);
  lv_obj_align_to(s_icon, s_pct, LV_ALIGN_OUT_LEFT_MID, -6, 0);
}

extern const complication_t comp_fin_reg = { "fin", "markets", "Market", build, update };
