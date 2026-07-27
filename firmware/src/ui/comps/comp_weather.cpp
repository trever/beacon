// Home complication: weather (1 slot, core -- no owning page, no arg). New content -- home_editorial.cpp
// deliberately dropped the weather panel it used to show (see that file's own header comment), so there
// is no shipped body to move; this follows shape A (name/value/secondary) like fin/ice/usage. build() is
// shared with those three via comp_common.h (convergence sweep, plan §10 item 1).
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "ui/fmt.h"
#include "core/datastore.h"
#include "config/location.h"

static lv_obj_t *s_name, *s_val, *s_pct;

static void build(lv_obj_t* slot) {
  comp_build_shape_a(slot, "--", &s_name, &s_val, &s_pct, nullptr);
}

static const char* wmo_label(uint16_t code) {
  for (uint16_t i = 0; i < WMO_MAP_COUNT; i++)
    if (WMO_MAP[i].code == code) return WMO_MAP[i].label;
  return "--";
}

static void update(void) {
  weather_rec_t w = ds_get_weather();
  if (comp_render_status_row(s_name, s_val, s_pct, "WEATHER", &w.hdr)) return;

  const beacon_theme_t* t = theme_active();
  char up[16]; comp_str_upper(up, sizeof(up), wmo_label(w.wmo_code));
  txt_set(s_name, up);

  char v[16]; fmt_temp(v, sizeof(v), w.temp_c);
  txt_set(s_val, v);
  txt_color(s_val, sv_dim(w.hdr.state) ? t->ink_dim : t->ink);

  char h[16]; snprintf(h, sizeof(h), "%.0f%% HUM", w.humidity_pct);
  txt_set(s_pct, h);
}

extern const complication_t comp_weather_reg = { "weather", "", "Weather", build, update };
