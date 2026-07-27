// Shared build/update bodies for the Home complication renderers -- see comp_common.h for why this
// file exists (the convergence sweep, plan §10 item 1). Each function's body below is the exact code
// that used to live inline in two or more comp_*.cpp files; only the widget-pointer plumbing (out
// params instead of file-statics) changed so one copy can serve every caller.
#include "ui/comps/comp_common.h"
#include "ui/comps/comp_registry.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/fonts/icons.h"
#include "ui/fmt.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "config/layout.h"
#include <ctype.h>

void comp_build_shape_a(lv_obj_t* slot, const char* name_init,
                        lv_obj_t** name, lv_obj_t** val, lv_obj_t** pct, lv_obj_t** icon) {
  const beacon_theme_t* t = theme_active();

  *name = lv_label_create(slot);
  lv_obj_add_style(*name, &S.slot, 0);
  lv_label_set_text(*name, name_init);
  lv_obj_align(*name, LV_ALIGN_TOP_LEFT, 0, 18);

  *val = lv_label_create(slot);
  lv_obj_add_style(*val, &S.display, 0);
  lv_label_set_text(*val, "--");
  lv_obj_align(*val, LV_ALIGN_TOP_RIGHT, 0, 10);

  // Percent and its trend glyph are separate labels: the glyph is a PUA codepoint that only renders
  // in a lucide face (ui/fonts/icons.h), so it cannot share a label with the number.
  *pct = lv_label_create(slot);
  lv_obj_add_style(*pct, &S.slot, 0);
  lv_label_set_text(*pct, "");
  lv_obj_align(*pct, LV_ALIGN_TOP_RIGHT, 0, 40);

  if (icon) {
    *icon = lv_label_create(slot);
    lv_obj_set_style_text_font(*icon, t->f_icon, 0);
    lv_obj_set_style_text_color(*icon, t->ink_dim, 0);
    lv_label_set_text(*icon, "");
    lv_obj_align_to(*icon, *pct, LV_ALIGN_OUT_LEFT_MID, -6, 0);
  }
}

void comp_build_shape_b(lv_obj_t* slot, const char* icon_glyph,
                        lv_obj_t** icon, lv_obj_t** line1, lv_obj_t** line2) {
  const beacon_theme_t* t = theme_active();

  *icon = lv_label_create(slot);
  lv_obj_set_style_text_font(*icon, t->f_icon, 0);
  lv_obj_set_style_text_color(*icon, t->ink_dim, 0);
  lv_label_set_text(*icon, icon_glyph);
  lv_obj_align(*icon, LV_ALIGN_TOP_LEFT, 0, 18);

  // Line 1: width-capped with a dot ellipsis so a long label truncates instead of running past the
  // safe area into the corner arc.
  *line1 = lv_label_create(slot);
  lv_obj_add_style(*line1, &S.body, 0);
  lv_label_set_long_mode(*line1, LV_LABEL_LONG_DOT);
  lv_obj_set_width(*line1, SCREEN_W - 2 * SAFE_INSET - 30);
  lv_label_set_text(*line1, "--");
  lv_obj_align(*line1, LV_ALIGN_TOP_LEFT, 26, 14);

  // Line 2: dimmed secondary line. Local y 40 -- see comp_agents.cpp re: the one intentional 4px move.
  *line2 = lv_label_create(slot);
  lv_obj_add_style(*line2, &S.slot, 0);
  lv_label_set_long_mode(*line2, LV_LABEL_LONG_DOT);
  lv_obj_set_width(*line2, SCREEN_W - 2 * SAFE_INSET - 30);
  lv_label_set_text(*line2, "");
  lv_obj_align(*line2, LV_ALIGN_TOP_LEFT, 26, 40);
}

void comp_render_market_row(lv_obj_t* val, lv_obj_t* pct, lv_obj_t* icon, tick_flash_t* flash,
                            const record_hdr_t* hdr, double value, double change_pct) {
  const beacon_theme_t* t = theme_active();

  bool live = (hdr->state == ST_LIVE);
  if (!live) tick_flash_reset(flash);   // don't flash on the link merely coming back

  char v[32]; fmt_usd(v, sizeof(v), value);
  txt_set(val, sv_placeholder(hdr->state) ? "--" : v);
  lv_color_t resting = sv_dim(hdr->state) ? t->ink_dim : t->ink;
  txt_color(val, live ? tick_flash_color(flash, value, t, resting) : resting);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), hdr, now_s())) {
    txt_set(pct, sbuf);
    txt_color(pct, sv_severe(hdr->state) ? t->down : t->ink_dim);
    lv_label_set_text(icon, "");   // no trend claim while the source is not live
    return;
  }
  char pb[16];
  int dir = fmt_change_num(pb, sizeof(pb), change_pct);
  txt_set(pct, pb);
  lv_color_t dc = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
  txt_color(pct, dc);
  lv_label_set_text(icon, dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
  lv_obj_set_style_text_color(icon, dc, 0);
  lv_obj_align_to(icon, pct, LV_ALIGN_OUT_LEFT_MID, -6, 0);
}

void comp_str_upper(char* out, size_t cap, const char* in) {
  size_t k = 0;
  for (; in && in[k] && k + 1 < cap; k++) out[k] = (char)toupper((unsigned char)in[k]);
  if (cap) out[k] = '\0';
}

bool comp_render_status_row(lv_obj_t* name, lv_obj_t* val, lv_obj_t* pct,
                            const char* name_text, const record_hdr_t* hdr) {
  char sbuf[24];
  if (!sv_status(sbuf, sizeof(sbuf), hdr, now_s())) return false;
  const beacon_theme_t* t = theme_active();
  txt_set(name, name_text);
  txt_set(val, "--");
  txt_set(pct, sbuf);
  txt_color(pct, sv_severe(hdr->state) ? t->down : t->ink_dim);
  return true;
}
