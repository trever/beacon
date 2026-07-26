// Calm Futurism (Nothing-esque) D4 RIN view.
// Sparse white-on-black, one faint red accent: lowercase eyebrow, centered Doto price hero,
// contract + change beneath, two quiet readouts (volume / last trade) on the lower band.
#include "ui/screen.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/theme.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "config/layout.h"
#include "core/datastore.h"
#include <Arduino.h>
static void update(void);

static lv_obj_t *s_eyebrow, *s_price, *s_contract, *s_change;
static lv_obj_t *s_vol, *s_vol_k, *s_time, *s_time_k, *s_status;

static lv_obj_t* key(lv_obj_t* page, const beacon_theme_t* t, const char* txt, lv_coord_t dx) {
  lv_obj_t* l = lv_label_create(page);
  lv_label_set_text(l, txt);
  lv_obj_set_style_text_font(l, t->f_body, 0);
  lv_obj_set_style_text_color(l, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(l, 2, 0);
  lv_obj_align(l, LV_ALIGN_BOTTOM_MID, dx, -SAFE_INSET);
  return l;
}

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();

  s_eyebrow = lv_label_create(page);
  lv_label_set_text(s_eyebrow, "d4 rin");
  lv_obj_set_style_text_font(s_eyebrow, t->f_body, 0);
  lv_obj_set_style_text_color(s_eyebrow, t->accent, 0);
  lv_obj_set_style_text_letter_space(s_eyebrow, 3, 0);
  lv_obj_align(s_eyebrow, LV_ALIGN_TOP_LEFT, SAFE_INSET + 4, SAFE_INSET + 8);

  s_price = lv_label_create(page);
  lv_label_set_text(s_price, "--");
  lv_obj_set_style_text_font(s_price, t->f_hero, 0);
  lv_obj_set_style_text_color(s_price, t->ink, 0);
  lv_obj_align(s_price, LV_ALIGN_CENTER, 0, -26);

  s_contract = lv_label_create(page);
  lv_label_set_text(s_contract, "--");
  lv_obj_set_style_text_font(s_contract, t->f_body, 0);
  lv_obj_set_style_text_color(s_contract, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_contract, 4, 0);
  lv_obj_align(s_contract, LV_ALIGN_CENTER, 0, 34);

  s_change = lv_label_create(page);
  lv_label_set_text(s_change, "--");
  lv_obj_set_style_text_font(s_change, t->f_display, 0);
  lv_obj_set_style_text_color(s_change, t->ink_dim, 0);
  lv_obj_align(s_change, LV_ALIGN_CENTER, 0, 66);

  s_vol = lv_label_create(page);
  lv_obj_set_style_text_font(s_vol, t->f_display, 0);
  lv_obj_set_style_text_color(s_vol, t->ink, 0);
  lv_obj_align(s_vol, LV_ALIGN_BOTTOM_MID, -60, -(SAFE_INSET + 20));
  s_vol_k = key(page, t, "volume", -60);

  s_time = lv_label_create(page);
  lv_obj_set_style_text_font(s_time, t->f_body, 0);
  lv_obj_set_style_text_color(s_time, t->ink, 0);
  lv_obj_align(s_time, LV_ALIGN_BOTTOM_MID, 60, -(SAFE_INSET + 20));
  s_time_k = key(page, t, "last trade", 60);

  s_status = lv_label_create(page);
  lv_obj_set_style_text_font(s_status, t->f_body, 0);
  lv_obj_set_style_text_color(s_status, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_status, 2, 0);
  lv_obj_align(s_status, LV_ALIGN_TOP_RIGHT, -(SAFE_INSET + 4), SAFE_INSET + 8);
  lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);

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
    lv_label_set_text(s_vol, "--");
    lv_label_set_text(s_time, "--");
  } else {
    ice_fmt_price(buf, sizeof(buf), f->last);       lv_label_set_text(s_price, buf);
    ice_fmt_strip(buf, sizeof(buf), f->strip, false); lv_label_set_text(s_contract, buf);
    fmt_change(buf, sizeof(buf), f->change_pct);    lv_label_set_text(s_change, buf);
    lv_obj_set_style_text_color(s_change, ice_change_color(t, f->change_pct), 0);
    ice_fmt_volume(buf, sizeof(buf), f->volume);    lv_label_set_text(s_vol, buf);
    ice_fmt_last_time(buf, sizeof(buf), f->last_time); lv_label_set_text(s_time, buf);
  }

  lv_color_t vc = sv_dim(r.hdr.state) ? t->ink_dim : t->ink;
  lv_obj_set_style_text_color(s_price, vc, 0);
  lv_obj_set_style_text_color(s_vol, vc, 0);
  lv_obj_set_style_text_color(s_time, vc, 0);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &r.hdr, now)) {
    lv_label_set_text(s_status, sbuf);
    lv_obj_set_style_text_color(s_status, sv_severe(r.hdr.state) ? t->down : t->ink_dim, 0);
    lv_obj_clear_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  }
}

extern const screen_view_t ice_calm_view = { build, update };
