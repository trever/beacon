// Home complication: the clock (2 slots, core -- no owning page). Verbatim body-move of
// home_editorial.cpp's hero/meridiem/date block (plan §4 items 3/7): only the coordinate FORM changes,
// page-absolute becoming container-local, via the -10px optical offset design §5.4 derives (the hero
// face's ink starts high in its glyph box, so hero sits at local y 4 and date at local y 96 rather than
// a naive top-aligned 0/108 -- the grid stays uniform at 62; this is a renderer constant, not a grid
// exception).
#include "ui/comps/comp_registry.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"

static lv_obj_t *s_clock, *s_merid, *s_date;

static void build(lv_obj_t* slot) {
  s_clock = lv_label_create(slot);
  lv_obj_add_style(s_clock, &S.hero, 0);
  lv_label_set_text(s_clock, "--:--");
  lv_obj_align(s_clock, LV_ALIGN_TOP_LEFT, 0, 4);

  // Meridiem needs its own label: the hero face is a digit/symbol subset with no A-Z
  // (fonts/MANIFEST.md), so "AM"/"PM" cannot render in the clock itself.
  s_merid = lv_label_create(slot);
  lv_obj_add_style(s_merid, &S.slot, 0);
  lv_label_set_text(s_merid, "");
  lv_obj_align_to(s_merid, s_clock, LV_ALIGN_OUT_RIGHT_BOTTOM, 8, -14);

  s_date = lv_label_create(slot);
  lv_obj_add_style(s_date, &S.slot, 0);
  lv_label_set_text(s_date, "--");
  lv_obj_align(s_date, LV_ALIGN_TOP_LEFT, 0, 96);
}

static void update(void) {
  render_clock_ex(s_clock, s_merid, s_date, "%a %d %b", txt_set);
}

extern const complication_t comp_clock_reg = { "clock", "", "Clock", build, update };
