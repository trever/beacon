// Home complication: ICE D4 RIN front-month contract (1 slot, owner "ice", no arg). Verbatim body-move
// of home_editorial.cpp's D4 RIN market row (plan §4 items 1/3) -- coordinate form changes from
// page-absolute to container-local; nothing else.
#include "ui/comps/comp_registry.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "ui/fonts/icons.h"
#include "ui/fmt.h"
#include "ui/tick_flash.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"

static lv_obj_t *s_name, *s_val, *s_icon, *s_pct;
static tick_flash_t s_flash;

static void build(lv_obj_t* slot) {
  const beacon_theme_t* t = theme_active();

  s_name = lv_label_create(slot);
  lv_obj_add_style(s_name, &S.slot, 0);
  lv_label_set_text(s_name, "D4 RIN");
  lv_obj_align(s_name, LV_ALIGN_TOP_LEFT, 0, 18);

  s_val = lv_label_create(slot);
  lv_obj_add_style(s_val, &S.display, 0);
  lv_label_set_text(s_val, "--");
  lv_obj_align(s_val, LV_ALIGN_TOP_RIGHT, 0, 10);

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
  ice_rec_t ice = ds_get_ice();
  const ice_contract_t* f = ice_front(&ice);

  if (!f) {
    // count == 0 with ST_LIVE is legal ("nothing listed"), not an error (CONVENTIONS.md).
    txt_set(s_val, "--");
    txt_set(s_pct, "no contracts");
    txt_color(s_pct, t->ink_dim);
    lv_label_set_text(s_icon, "");
    return;
  }

  bool live = (ice.hdr.state == ST_LIVE);
  if (!live) tick_flash_reset(&s_flash);

  char v[32]; fmt_usd(v, sizeof(v), f->last);
  txt_set(s_val, sv_placeholder(ice.hdr.state) ? "--" : v);
  lv_color_t resting = sv_dim(ice.hdr.state) ? t->ink_dim : t->ink;
  txt_color(s_val, live ? tick_flash_color(&s_flash, f->last, t, resting) : resting);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &ice.hdr, now_s())) {
    txt_set(s_pct, sbuf);
    txt_color(s_pct, sv_severe(ice.hdr.state) ? t->down : t->ink_dim);
    lv_label_set_text(s_icon, "");
    return;
  }
  // change_pct is ALREADY a percent from the wire -- feed it straight to fmt_change_num.
  char pb[16];
  int dir = fmt_change_num(pb, sizeof(pb), f->change_pct);
  txt_set(s_pct, pb);
  lv_color_t dc = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
  txt_color(s_pct, dc);
  lv_label_set_text(s_icon, dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
  lv_obj_set_style_text_color(s_icon, dc, 0);
  lv_obj_align_to(s_icon, s_pct, LV_ALIGN_OUT_LEFT_MID, -6, 0);
}

extern const complication_t comp_ice_reg = { "ice", "ice", "D4 RIN", build, update };
