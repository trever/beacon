// Single-instrument graph screen (S&P 500 intraday).
//
// Headline figure + trend, over a full-width intraday trace. The graph is the reusable ui/graph
// component, so a future screen wanting a sparkline reuses it rather than re-deriving chart scaling.
#include "ui/screen.h"
#include "ui/fmt.h"
#include "ui/graph.h"
#include "ui/tick_flash.h"
#include "ui/fonts/icons.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "config/chart.h"
#include "config/ticker_table.h"
#include "fetch/series.h"
#include "core/datastore.h"
#include <math.h>

static lv_obj_t *s_slot, *s_cur, *s_price, *s_pct, *s_icon, *s_range;
static graph_t   s_graph;
static tick_flash_t s_flash;

#define GRAPH_H 150

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();
  // The instrument is configurable per page, so the header follows the resolved row, not CHART_LABEL.
  char label[TKR_NAME_LEN];
  chart_display_label(label, sizeof(label));
  s_slot = build_header(page, label);

  // Currency mark in a full-ASCII face: the hero subset has no '$' (fonts/MANIFEST.md), so putting it
  // in the hero string draws a missing-glyph box.
  s_cur = lv_label_create(page);
  lv_obj_add_style(s_cur, &S.slot, 0);
  lv_label_set_text(s_cur, "$");
  lv_obj_align(s_cur, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 44);

  s_price = lv_label_create(page);
  lv_obj_add_style(s_price, &S.hero, 0);
  lv_label_set_text(s_price, "--");
  lv_obj_align(s_price, LV_ALIGN_TOP_LEFT, SAFE_INSET + 18, SAFE_INSET + 28);

  s_pct = lv_label_create(page);
  lv_obj_add_style(s_pct, &S.display, 0);
  lv_label_set_text(s_pct, "--");
  lv_obj_align(s_pct, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET + 60);

  s_icon = lv_label_create(page);
  lv_obj_set_style_text_font(s_icon, t->f_icon_lg, 0);
  lv_obj_set_style_text_color(s_icon, t->ink_dim, 0);
  lv_label_set_text(s_icon, "");
  lv_obj_align_to(s_icon, s_pct, LV_ALIGN_OUT_LEFT_MID, -8, 0);

  // Full-width trace. Width is the safe content box, so it spans the panel without entering the arcs.
  graph_create(&s_graph, page, SCREEN_W - 2 * SAFE_INSET, GRAPH_H, SERIES_MAX, true);
  lv_obj_align(s_graph.chart, LV_ALIGN_TOP_MID, 0, SAFE_INSET + 150);

  // Day range under the trace: the hairlines imply the band, this names it.
  s_range = lv_label_create(page);
  lv_obj_add_style(s_range, &S.slot, 0);
  lv_label_set_text(s_range, "");
  lv_obj_align(s_range, LV_ALIGN_TOP_MID, 0, SAFE_INSET + 312);
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  series_rec_t r = ds_get_series();
  uint32_t now = now_s();
  bool live = (r.hdr.state == ST_LIVE);
  bool have = r.count > 0 && !sv_placeholder(r.hdr.state);

  char buf[32];
  if (!have) {
    txt_set(s_price, "--");
    txt_set(s_pct, "--");
    lv_label_set_text(s_icon, "");
    lv_obj_add_flag(s_cur, LV_OBJ_FLAG_HIDDEN);
    txt_set(s_range, "");
    graph_clear(&s_graph);
    tick_flash_reset(&s_flash);
  } else {
    lv_obj_clear_flag(s_cur, LV_OBJ_FLAG_HIDDEN);
    fmt_value(buf, sizeof(buf), r.last);   // bare: the "$" is its own label beside the hero
    txt_set(s_price, buf);

    // Day change against previousClose. Derived here rather than stored: prev_close is the basis and
    // `last` moves every poll, so a stored percent would go stale between fetches.
    double pct = (r.prev_close != 0.0) ? (r.last - r.prev_close) / r.prev_close * 100.0 : 0.0;
    int dir = fmt_change_num(buf, sizeof(buf), pct);
    txt_set(s_pct, buf);
    lv_color_t dc = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
    txt_color(s_pct, dc);
    lv_label_set_text(s_icon, dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
    lv_obj_set_style_text_color(s_icon, dc, 0);
    lv_obj_align_to(s_icon, s_pct, LV_ALIGN_OUT_LEFT_MID, -8, 0);

    graph_set_series(&s_graph, r.v, r.count, r.lo, r.hi, dir);

    char lo[16], hi[16];
    fmt_value(lo, sizeof(lo), r.lo);
    fmt_value(hi, sizeof(hi), r.hi);
    snprintf(buf, sizeof(buf), "%s - %s", lo, hi);
    txt_set(s_range, buf);

    if (!live) tick_flash_reset(&s_flash);   // a returning link is not a tick
    lv_color_t resting = sv_dim(r.hdr.state) ? t->ink_dim : t->ink;
    txt_color(s_price, live ? tick_flash_color(&s_flash, r.last, t, resting) : resting);
  }

  slot_set(s_slot, "", &r.hdr, now);
}

extern const screen_view_t chart_editorial_view = { build, update };
