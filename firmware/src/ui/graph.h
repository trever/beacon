#pragma once
#include <lvgl.h>
#include <stdint.h>
#include <stdbool.h>

// Full-width line graph COMPONENT. One instance renders one series; the caller owns the handle so a
// screen can hold several (a stacked mini-graph column, say) without a registry.
//
// Deliberately a thin wrapper over lv_chart rather than a custom DRAW_MAIN trace: lv_chart already
// handles point scaling, clipping and partial-redraw invalidation correctly, and the render cost lands
// in the same partial-render path everything else uses (docs/perf.md). A bespoke trace would have to
// re-solve all three.
//
// Styling comes from theme tokens only -- no colours here. The line colour is chosen by direction so
// the graph agrees with the change figure beside it.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  lv_obj_t*          chart;
  lv_chart_series_t* ser;
  uint16_t           cap;    // points the chart was created for
  lv_obj_t*          hairline_lo;   // optional baseline rules (NULL when not requested)
  lv_obj_t*          hairline_hi;
} graph_t;

// Create into `parent` at the given size. `cap` is the maximum point count (the caller's SERIES_MAX).
// `rules` draws faint hi/lo hairlines behind the trace, which give the line a readable range without
// axis labels -- there is no room for axis text on a 466 px round panel.
void graph_create(graph_t* g, lv_obj_t* parent, lv_coord_t w, lv_coord_t h, uint16_t cap, bool rules);

// Replace the series. `n` is clamped to thecreated capacity. lo/hi set the y-range; pass the series min/max
// (series_rec_t precomputes them). `dir` picks the token colour: >0 up, <0 down, 0 neutral.
//
// A FLAT range (lo == hi, e.g. a single point or a halted market) is widened symmetrically -- lv_chart
// with a zero-height range renders the line pinned to an edge, which reads as a crash to the bottom.
void graph_set_series(graph_t* g, const float* pts, uint16_t n, float lo, float hi, int dir);

// Show the empty state: no trace. Used for LOADING and for a source with no usable points.
void graph_clear(graph_t* g);

#ifdef __cplusplus
}
#endif
