// HUD lane D4 RIN view. Centered hero quote with the contract month above and the signed change
// below; volume + last-trade sit on the lower band. Styling follows this lane's palette and casing.
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

static lv_obj_t *s_eyebrow, *s_contract, *s_price, *s_change, *s_meta, *s_status;

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();

  s_eyebrow = lv_label_create(page);
  lv_label_set_text(s_eyebrow, "D4 RIN // ICE");
  lv_obj_set_style_text_font(s_eyebrow, t->f_mono, 0);
  lv_obj_set_style_text_color(s_eyebrow, t->accent, 0);
  lv_obj_set_style_text_letter_space(s_eyebrow, 3, 0);
  lv_obj_align(s_eyebrow, LV_ALIGN_TOP_MID, 0, SAFE_INSET);

  s_contract = lv_label_create(page);
  lv_label_set_text(s_contract, "--");
  lv_obj_set_style_text_font(s_contract, t->f_mono, 0);
  lv_obj_set_style_text_color(s_contract, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_contract, 3, 0);
  lv_obj_align(s_contract, LV_ALIGN_CENTER, 0, -78);

  s_price = lv_label_create(page);
  lv_label_set_text(s_price, "--");
  lv_obj_set_style_text_font(s_price, t->f_hero, 0);
  lv_obj_set_style_text_color(s_price, t->ink, 0);
  lv_obj_align(s_price, LV_ALIGN_CENTER, 0, -14);

  s_change = lv_label_create(page);
  lv_label_set_text(s_change, "--");
  lv_obj_set_style_text_font(s_change, t->f_display, 0);
  lv_obj_set_style_text_color(s_change, t->ink_dim, 0);
  lv_obj_align(s_change, LV_ALIGN_CENTER, 0, 56);

  s_meta = lv_label_create(page);
  lv_label_set_text(s_meta, "--");
  lv_obj_set_style_text_font(s_meta, t->f_mono, 0);
  lv_obj_set_style_text_color(s_meta, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_meta, 1, 0);
  lv_obj_align(s_meta, LV_ALIGN_BOTTOM_MID, 0, -(SAFE_INSET + 4));

  s_status = lv_label_create(page);
  lv_obj_set_style_text_font(s_status, t->f_mono, 0);
  lv_obj_set_style_text_color(s_status, t->ink_dim, 0);
  lv_obj_align(s_status, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET);
  lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);

  update();
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  ice_rec_t r = ds_get_ice();
  uint32_t now = now_s();
  const ice_contract_t* f = ice_front(&r);
  char buf[32], vol[24], tm[24];

  if (!f || sv_placeholder(r.hdr.state)) {
    lv_label_set_text(s_price, "--");
    lv_label_set_text(s_contract, "--");
    lv_label_set_text(s_change, "--");
    lv_label_set_text(s_meta, "--");
  } else {
    ice_fmt_price(buf, sizeof(buf), f->last);          lv_label_set_text(s_price, buf);
    ice_fmt_strip(buf, sizeof(buf), f->strip, true); lv_label_set_text(s_contract, buf);
    fmt_change(buf, sizeof(buf), f->change_pct);       lv_label_set_text(s_change, buf);
    lv_obj_set_style_text_color(s_change, ice_change_color(t, f->change_pct), 0);
    ice_fmt_volume(vol, sizeof(vol), f->volume);
    ice_fmt_last_time(tm, sizeof(tm), f->last_time);
    snprintf(buf, sizeof(buf), "VOL %s   %s", vol, tm);
    lv_label_set_text(s_meta, buf);
  }
  lv_obj_set_style_text_color(s_price, sv_dim(r.hdr.state) ? t->ink_dim : t->ink, 0);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &r.hdr, now)) {
    lv_label_set_text(s_status, sbuf);
    lv_obj_set_style_text_color(s_status, sv_severe(r.hdr.state) ? t->down : t->ink_dim, 0);
    lv_obj_clear_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  } else {
    lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);
  }
}

extern const screen_view_t ice_hud_view = { build, update };
