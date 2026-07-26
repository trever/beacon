// Editorial Index D4 RIN view.
// Left-aligned masthead, oversized figure, then a hairline-ruled table of every listed contract --
// the editorial lane treats the contract strip as a table of record, not a dashboard.
#include "ui/screen.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/theme.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "ui/tick_flash.h"
#include "ui/fonts/icons.h"
#include "config/layout.h"
#include "core/datastore.h"
#include <Arduino.h>
static void update(void);

#define ICE_ED_ROWS ICE_CONTRACTS_MAX
static lv_obj_t *s_eyebrow, *s_cur, *s_price, *s_contract, *s_change, *s_chg_icon, *s_status;
static tick_flash_t s_price_flash;
static tick_flash_t s_row_flash[ICE_CONTRACTS_MAX];
static lv_obj_t *s_row_strip[ICE_ED_ROWS], *s_row_val[ICE_ED_ROWS], *s_row_chg[ICE_ED_ROWS], *s_rule[ICE_ED_ROWS];

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();

  s_eyebrow = lv_label_create(page);
  lv_label_set_text(s_eyebrow, "D4 RIN");
  lv_obj_add_style(s_eyebrow, &S.eyebrow, 0);
  lv_obj_align(s_eyebrow, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET);

  s_status = lv_label_create(page);
  lv_obj_set_style_text_font(s_status, t->f_mono, 0);
  lv_obj_set_style_text_color(s_status, t->ink_dim, 0);
  lv_obj_align(s_status, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET);
  lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);

  // Currency mark in a full-ASCII face, set smaller and top-aligned to the figure. The hero subset has
  // no '$' (fonts/MANIFEST.md), so putting it in the hero string draws a missing-glyph box.
  s_cur = lv_label_create(page);
  lv_label_set_text(s_cur, "$");
  lv_obj_set_style_text_font(s_cur, t->f_display, 0);
  lv_obj_set_style_text_color(s_cur, t->ink_dim, 0);
  lv_obj_align(s_cur, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 46);

  s_price = lv_label_create(page);
  lv_label_set_text(s_price, "--");
  lv_obj_set_style_text_font(s_price, t->f_hero, 0);
  lv_obj_set_style_text_color(s_price, t->ink, 0);
  lv_obj_align(s_price, LV_ALIGN_TOP_LEFT, SAFE_INSET + 24, SAFE_INSET + 34);

  s_contract = lv_label_create(page);
  lv_obj_set_style_text_font(s_contract, t->f_mono, 0);
  lv_obj_set_style_text_color(s_contract, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_contract, 2, 0);
  lv_obj_align(s_contract, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 142);

  s_change = lv_label_create(page);
  lv_obj_set_style_text_font(s_change, t->f_display, 0);
  lv_obj_align(s_change, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET + 132);

  // Trend glyph in its own label (lucide PUA codepoints do not render in a text font, icons.h).
  s_chg_icon = lv_label_create(page);
  lv_obj_set_style_text_font(s_chg_icon, t->f_icon_lg, 0);
  lv_obj_set_style_text_color(s_chg_icon, t->ink_dim, 0);
  lv_label_set_text(s_chg_icon, "");
  lv_obj_align_to(s_chg_icon, s_change, LV_ALIGN_OUT_LEFT_MID, -8, 0);

  for (int i = 0; i < ICE_ED_ROWS; i++) {
    lv_coord_t y = SAFE_INSET + 186 + i * 34;
    lv_obj_t* rule = lv_obj_create(page);
    lv_obj_remove_style_all(rule);
    lv_obj_set_size(rule, SCREEN_W - 2 * SAFE_INSET, 1);
    lv_obj_set_style_bg_color(rule, t->line, 0);
    lv_obj_set_style_bg_opa(rule, LV_OPA_COVER, 0);
    lv_obj_align(rule, LV_ALIGN_TOP_MID, 0, y - 8);
    s_rule[i] = rule;

    s_row_strip[i] = lv_label_create(page);
    lv_obj_set_style_text_font(s_row_strip[i], t->f_mono, 0);
    lv_obj_set_style_text_color(s_row_strip[i], t->ink_dim, 0);
    lv_obj_align(s_row_strip[i], LV_ALIGN_TOP_LEFT, SAFE_INSET, y);

    s_row_val[i] = lv_label_create(page);
    lv_obj_set_style_text_font(s_row_val[i], t->f_display, 0);
    lv_obj_set_style_text_color(s_row_val[i], t->ink, 0);
    lv_obj_align(s_row_val[i], LV_ALIGN_TOP_MID, 20, y - 4);

    s_row_chg[i] = lv_label_create(page);
    lv_obj_set_style_text_font(s_row_chg[i], t->f_mono, 0);
    lv_obj_align(s_row_chg[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y);
  }
  update();
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  ice_rec_t r = ds_get_ice();
  uint32_t now = now_s();
  const ice_contract_t* f = ice_front(&r);
  char buf[32];

  if (!f || sv_placeholder(r.hdr.state)) {
    lv_label_set_text(s_price, "--");
    lv_label_set_text(s_contract, "--");
    lv_label_set_text(s_change, "--");
    lv_label_set_text(s_chg_icon, "");
  } else {
    ice_fmt_price(buf, sizeof(buf), f->last);         lv_label_set_text(s_price, buf);
    ice_fmt_strip(buf, sizeof(buf), f->strip, true);  lv_label_set_text(s_contract, buf);
    int dir = fmt_change_num(buf, sizeof(buf), f->change_pct);
    lv_label_set_text(s_change, buf);
    lv_color_t dc = ice_change_color(t, f->change_pct);
    lv_obj_set_style_text_color(s_change, dc, 0);
    lv_label_set_text(s_chg_icon, dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
    lv_obj_set_style_text_color(s_chg_icon, dc, 0);
    lv_obj_align_to(s_chg_icon, s_change, LV_ALIGN_OUT_LEFT_MID, -8, 0);
  }
  { bool live = (r.hdr.state == ST_LIVE) && f;
    lv_color_t resting = sv_dim(r.hdr.state) ? t->ink_dim : t->ink;
    if (!live) tick_flash_reset(&s_price_flash);
    lv_obj_set_style_text_color(s_price,
      live ? tick_flash_color(&s_price_flash, f->last, t, resting) : resting, 0); }
  // No quote => no currency mark; "$--" reads like a broken price.
  if (!f || sv_placeholder(r.hdr.state)) lv_obj_add_flag(s_cur, LV_OBJ_FLAG_HIDDEN);
  else                                   lv_obj_clear_flag(s_cur, LV_OBJ_FLAG_HIDDEN);

  for (int i = 0; i < ICE_ED_ROWS; i++) {
    bool on = i < r.count;
    // Hide the rule too: a ruled but empty row reads as a missing quote rather than an absent contract.
    if (!on) {
      lv_obj_add_flag(s_row_strip[i], LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_val[i], LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_chg[i], LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_rule[i], LV_OBJ_FLAG_HIDDEN);
      continue;
    }
    lv_obj_clear_flag(s_row_strip[i], LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(s_row_val[i], LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(s_row_chg[i], LV_OBJ_FLAG_HIDDEN);
    lv_obj_clear_flag(s_rule[i], LV_OBJ_FLAG_HIDDEN);
    ice_fmt_strip(buf, sizeof(buf), r.c[i].strip, true); lv_label_set_text(s_row_strip[i], buf);
    fmt_usd(buf, sizeof(buf), r.c[i].last);              lv_label_set_text(s_row_val[i], buf);
    fmt_change(buf, sizeof(buf), r.c[i].change_pct);     lv_label_set_text(s_row_chg[i], buf);
    lv_obj_set_style_text_color(s_row_chg[i], ice_change_color(t, r.c[i].change_pct), 0);
    // Rows keep the compact ASCII caret form: a per-row icon label in this dense table costs more
    // than it reads. The headline above carries the lucide glyph.
    { bool rlive = (r.hdr.state == ST_LIVE);
      if (!rlive) tick_flash_reset(&s_row_flash[i]);
      lv_obj_set_style_text_color(s_row_val[i],
        rlive ? tick_flash_color(&s_row_flash[i], r.c[i].last, t, t->ink) : t->ink, 0); }
  }

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &r.hdr, now)) {
    lv_label_set_text(s_status, sbuf);
    lv_obj_set_style_text_color(s_status, sv_severe(r.hdr.state) ? t->down : t->ink_dim, 0);
    lv_obj_clear_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  }
}

extern const screen_view_t ice_editorial_view = { build, update };
