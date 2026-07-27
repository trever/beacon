// Home complication: weather (1 slot, core -- no owning page, no arg). New content -- home_editorial.cpp
// deliberately dropped the weather panel it used to show (see that file's own header comment), so there
// is no shipped body to move; this follows shape A (name/value/secondary) like fin/ice/usage.
#include "ui/comps/comp_registry.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/fmt.h"
#include "core/datastore.h"
#include "config/location.h"
#include <ctype.h>

static lv_obj_t *s_name, *s_val, *s_pct;

static void build(lv_obj_t* slot) {
  s_name = lv_label_create(slot);
  lv_obj_add_style(s_name, &S.slot, 0);
  lv_label_set_text(s_name, "--");
  lv_obj_align(s_name, LV_ALIGN_TOP_LEFT, 0, 18);

  s_val = lv_label_create(slot);
  lv_obj_add_style(s_val, &S.display, 0);
  lv_label_set_text(s_val, "--");
  lv_obj_align(s_val, LV_ALIGN_TOP_RIGHT, 0, 10);

  s_pct = lv_label_create(slot);
  lv_obj_add_style(s_pct, &S.slot, 0);
  lv_label_set_text(s_pct, "");
  lv_obj_align(s_pct, LV_ALIGN_TOP_RIGHT, 0, 40);
}

static const char* wmo_label(uint16_t code) {
  for (uint16_t i = 0; i < WMO_MAP_COUNT; i++)
    if (WMO_MAP[i].code == code) return WMO_MAP[i].label;
  return "--";
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  weather_rec_t w = ds_get_weather();

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &w.hdr, now_s())) {
    txt_set(s_name, "WEATHER");
    txt_set(s_val, "--");
    txt_set(s_pct, sbuf);
    txt_color(s_pct, sv_severe(w.hdr.state) ? t->down : t->ink_dim);
    return;
  }

  char up[16]; const char* label = wmo_label(w.wmo_code); size_t k = 0;
  for (; label[k] && k + 1 < sizeof(up); k++) up[k] = (char)toupper((unsigned char)label[k]);
  up[k] = '\0';
  txt_set(s_name, up);

  char v[16]; fmt_temp(v, sizeof(v), w.temp_c);
  txt_set(s_val, v);
  txt_color(s_val, sv_dim(w.hdr.state) ? t->ink_dim : t->ink);

  char h[16]; snprintf(h, sizeof(h), "%.0f%% HUM", w.humidity_pct);
  txt_set(s_pct, h);
}

extern const complication_t comp_weather_reg = { "weather", "", "Weather", build, update };
