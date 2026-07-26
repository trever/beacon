#include "ui/graph.h"
#include "ui/theme.h"

// Padding inside the chart box. The trace needs a little headroom or the peak sits on the border and
// reads as clipped.
#define GRAPH_PAD_V 6

void graph_create(graph_t* g, lv_obj_t* parent, lv_coord_t w, lv_coord_t h, uint16_t cap, bool rules) {
  const beacon_theme_t* t = theme_active();
  g->cap = cap;
  g->hairline_lo = g->hairline_hi = nullptr;

  if (rules) {
    // Behind the chart (created first => lower z-order): a faint top and bottom rule that imply the
    // range. Cheaper and quieter than axis ticks, and legible on a black panel.
    for (int i = 0; i < 2; i++) {
      lv_obj_t* r = lv_obj_create(parent);
      lv_obj_remove_style_all(r);
      lv_obj_set_size(r, w, 1);
      lv_obj_set_style_bg_color(r, t->line, 0);
      lv_obj_set_style_bg_opa(r, LV_OPA_COVER, 0);
      if (i == 0) g->hairline_hi = r; else g->hairline_lo = r;
    }
  }

  g->chart = lv_chart_create(parent);
  lv_obj_remove_style_all(g->chart);
  lv_obj_set_size(g->chart, w, h);
  lv_chart_set_type(g->chart, LV_CHART_TYPE_LINE);
  lv_chart_set_point_count(g->chart, cap);
  lv_chart_set_div_line_count(g->chart, 0, 0);     // no grid: the hairlines carry the range
  lv_chart_set_update_mode(g->chart, LV_CHART_UPDATE_MODE_SHIFT);
  lv_obj_set_style_pad_all(g->chart, 0, 0);
  lv_obj_set_style_bg_opa(g->chart, LV_OPA_TRANSP, 0);
  lv_obj_set_style_border_width(g->chart, 0, 0);
  lv_obj_clear_flag(g->chart, LV_OBJ_FLAG_SCROLLABLE);
  // Point markers off: at ~17 px per point a dot per bucket turns the trace into a dotted mess.
  lv_obj_set_style_size(g->chart, 0, LV_PART_INDICATOR);
  lv_obj_set_style_line_width(g->chart, t->stroke_med, LV_PART_ITEMS);
  g->ser = lv_chart_add_series(g->chart, t->accent, LV_CHART_AXIS_PRIMARY_Y);
}

void graph_clear(graph_t* g) {
  if (!g->chart || !g->ser) return;
  // LV_CHART_POINT_NONE is the documented "no value here" sentinel: the trace breaks rather than
  // dropping to zero, which is what an empty state should look like.
  for (uint16_t i = 0; i < g->cap; i++)
    lv_chart_set_value_by_id(g->chart, g->ser, i, LV_CHART_POINT_NONE);
  lv_chart_refresh(g->chart);
}

void graph_set_series(graph_t* g, const float* pts, uint16_t n, float lo, float hi, int dir) {
  if (!g->chart || !g->ser || !pts || n == 0) { graph_clear(g); return; }
  const beacon_theme_t* t = theme_active();
  if (n > g->cap) n = g->cap;

  // A zero-height range pins the line to an edge, which reads as a crash rather than "flat". Widen
  // symmetrically so a flat/halted series renders as a centred horizontal line.
  if (hi <= lo) { float mid = lo; lo = mid - 1.0f; hi = mid + 1.0f; }

  // lv_chart takes integer y values, so scale the float series into a fixed span. 1000 steps is far
  // finer than the ~200 px of chart height can show, so the quantisation is invisible.
  const int32_t SPAN = 1000;
  lv_chart_set_range(g->chart, LV_CHART_AXIS_PRIMARY_Y, 0, SPAN);

  // Right-align: the newest point sits at the right edge. With n < cap the OLD end is blanked, so a
  // partial day does not stretch to fill the width and imply data it does not have.
  uint16_t blank = (uint16_t)(g->cap - n);
  for (uint16_t i = 0; i < blank; i++)
    lv_chart_set_value_by_id(g->chart, g->ser, i, LV_CHART_POINT_NONE);
  for (uint16_t i = 0; i < n; i++) {
    float f = (pts[i] - lo) / (hi - lo);
    if (f < 0) f = 0; if (f > 1) f = 1;
    lv_chart_set_value_by_id(g->chart, g->ser, blank + i, (lv_coord_t)(f * SPAN));
  }

  lv_color_t c = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
  lv_chart_set_series_color(g->chart, g->ser, c);
  lv_chart_refresh(g->chart);

  if (g->hairline_hi && g->hairline_lo) {
    lv_obj_align_to(g->hairline_hi, g->chart, LV_ALIGN_OUT_TOP_MID, 0, GRAPH_PAD_V);
    lv_obj_align_to(g->hairline_lo, g->chart, LV_ALIGN_OUT_BOTTOM_MID, 0, -GRAPH_PAD_V);
  }
}
