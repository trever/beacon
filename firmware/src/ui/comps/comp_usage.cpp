// Home complication: one AI-usage provider (1 slot, owner "agents"), selected by `arg` (a provider id).
// New content -- there is no today's-Home body to move, since Home never showed usage before (the
// dedicated usage/LIMITS screen was removed before this repo's complication work started; see
// docs/codemap.md). Shape A, like fin/ice/weather: name = provider label, value = the 5h window pct,
// secondary = the 7d window pct (no trend glyph -- a usage percentage has no up/down claim to make).
//
// pct < 0 means null/unavailable (JSON null) -- NEVER feed it to a bar/gauge; here there is no bar at
// all (Phase 1 complications are plain text), but the same rule applies to the text: render "--", not a
// negative percent.
// build() is shared with comp_fin/comp_ice/comp_weather via comp_common.h (convergence sweep, plan §10
// item 1): all four are shape-A rows (name/value/change), usage/weather just pass icon=NULL since
// neither makes a trend claim.
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "core/comp_state.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"
#include <string.h>

static lv_obj_t *s_name, *s_val, *s_pct;

static void build(lv_obj_t* slot) {
  comp_build_shape_a(slot, "--", &s_name, &s_val, &s_pct, nullptr);
}

static const usage_provider_t* find_provider(const usage_rec_t* u, const char* arg) {
  for (uint8_t i = 0; i < u->count; i++)
    if (strncmp(u->p[i].id, arg, USAGE_ID_LEN) == 0) return &u->p[i];
  return nullptr;
}

static void update(void) {
  usage_rec_t u = ds_get_usage();
  if (comp_render_status_row(s_name, s_val, s_pct, "USAGE", &u.hdr)) return;

  const beacon_theme_t* t = theme_active();
  char arg[COMP_ARG_LEN];
  bool has_arg = comp_arg("usage", arg, sizeof(arg));
  const usage_provider_t* p = has_arg ? find_provider(&u, arg) : nullptr;
  if (!p) {
    char up[COMP_ARG_LEN]; comp_str_upper(up, sizeof(up), has_arg ? arg : "");
    txt_set(s_name, has_arg ? up : "USAGE");
    txt_set(s_val, "--");
    txt_set(s_pct, "not in list");
    txt_color(s_pct, t->ink_dim);
    return;
  }

  char up[USAGE_LABEL_LEN]; comp_str_upper(up, sizeof(up), p->label);
  txt_set(s_name, up);

  lv_color_t val_c = p->stale ? t->ink_dim : t->ink;
  if (p->h5.pct < 0) txt_set(s_val, "--");
  else { char v[8]; snprintf(v, sizeof(v), "%d%%", p->h5.pct); txt_set(s_val, v); }
  txt_color(s_val, val_c);

  if (p->d7.pct < 0) txt_set(s_pct, "--");
  else { char v[16]; snprintf(v, sizeof(v), "7D %d%%", p->d7.pct); txt_set(s_pct, v); }
  txt_color(s_pct, t->ink_dim);
}

extern const complication_t comp_usage_reg = { "usage", "agents", "Usage", build, update };
