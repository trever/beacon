// Blueprint lane D4 RIN view. Contract month and quote stack on the vertical centre line with a
// measured rule beneath the figure; volume and last-trade read as annotations rather than data cells.
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

static lv_obj_t *s_eyebrow, *s_contract, *s_price, *s_rule, *s_change, *s_vol, *s_time, *s_status;

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();

  s_eyebrow = lv_label_create(page);
  lv_label_set_text(s_eyebrow, "D4 RIN");
  lv_obj_set_style_text_font(s_eyebrow, t->f_mono, 0);
  lv_obj_set_style_text_color(s_eyebrow, t->accent, 0);
  lv_obj_set_style_text_letter_space(s_eyebrow, 3, 0);
  lv_obj_align(s_eyebrow, LV_ALIGN_TOP_MID, 0, SAFE_INSET);

  s_contract = lv_label_create(page);
  lv_label_set_text(s_contract, "--");
  lv_obj_set_style_text_font(s_contract, t->f_body, 0);
  lv_obj_set_style_text_color(s_contract, t->ink_dim, 0);
  lv_obj_set_style_text_letter_space(s_contract, 3, 0);
  lv_obj_align(s_contract, LV_ALIGN_CENTER, 0, -84);

  s_price = lv_label_create(page);
  lv_label_set_text(s_price, "--");
  lv_obj_set_style_text_font(s_price, t->f_hero, 0);
  lv_obj_set_style_text_color(s_price, t->ink, 0);
  lv_obj_align(s_price, LV_ALIGN_CENTER, 0, -20);

  // Measured rule under the figure: the lane's dimension-line motif, sized to the safe content width.
  s_rule = lv_obj_create(page);
  lv_obj_remove_style_all(s_rule);
  lv_obj_set_size(s_rule, 180, 1);
  lv_obj_set_style_bg_color(s_rule, t->line, 0);
  lv_obj_set_style_bg_opa(s_rule, LV_OPA_COVER, 0);
  lv_obj_align(s_rule, LV_ALIGN_CENTER, 0, 34);

  s_change = lv_label_create(page);
  lv_label_set_text(s_change, "--");
  lv_obj_set_style_text_font(s_change, t->f_display, 0);
  lv_obj_set_style_text_color(s_change, t->ink_dim, 0);
  lv_obj_align(s_change, LV_ALIGN_CENTER, 0, 62);

  s_vol = lv_label_create(page);
  lv_label_set_text(s_vol, "--");
  lv_obj_set_style_text_font(s_vol, t->f_body, 0);
  lv_obj_set_style_text_color(s_vol, t->ink_dim, 0);
  lv_obj_align(s_vol, LV_ALIGN_BOTTOM_LEFT, SAFE_INSET + 8, -(SAFE_INSET + 4));

  s_time = lv_label_create(page);
  lv_label_set_text(s_time, "--");
  lv_obj_set_style_text_font(s_time, t->f_body, 0);
  lv_obj_set_style_text_color(s_time, t->ink_dim, 0);
  lv_obj_align(s_time, LV_ALIGN_BOTTOM_RIGHT, -(SAFE_INSET + 8), -(SAFE_INSET + 4));

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
  char buf[32];

  if (!f || sv_placeholder(r.hdr.state)) {
    lv_label_set_text(s_price, "--");
    lv_label_set_text(s_contract, "--");
    lv_label_set_text(s_change, "--");
    lv_label_set_text(s_vol, "--");
    lv_label_set_text(s_time, "--");
  } else {
    ice_fmt_price(buf, sizeof(buf), f->last);            lv_label_set_text(s_price, buf);
    ice_fmt_strip(buf, sizeof(buf), f->strip, true); lv_label_set_text(s_contract, buf);
    fmt_change(buf, sizeof(buf), f->change_pct);         lv_label_set_text(s_change, buf);
    lv_obj_set_style_text_color(s_change, ice_change_color(t, f->change_pct), 0);
    char v[24]; ice_fmt_volume(v, sizeof(v), f->volume);
    snprintf(buf, sizeof(buf), "vol %s", v);             lv_label_set_text(s_vol, buf);
    ice_fmt_last_time(buf, sizeof(buf), f->last_time);   lv_label_set_text(s_time, buf);
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

extern const screen_view_t ice_blueprint_view = { build, update };
