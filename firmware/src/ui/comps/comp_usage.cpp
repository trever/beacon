// Home complication: one AI-usage provider (1 slot, owner "agents"), selected by `arg` (a provider id).
// New content -- there is no today's-Home body to move, since Home never showed usage before (the
// dedicated usage/LIMITS screen was removed before this repo's complication work started; see
// docs/codemap.md). Shape A, like fin/ice/weather: name = provider label, value = the 5h window pct,
// secondary = the 7d window pct (no trend glyph -- a usage percentage has no up/down claim to make).
//
// pct < 0 means null/unavailable (JSON null) -- NEVER feed it to a bar/gauge; here there is no bar at
// all (Phase 1 complications are plain text), but the same rule applies to the text: render "--", not a
// negative percent.
#include "ui/comps/comp_registry.h"
#include "core/comp_state.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"
#include <string.h>
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

static const usage_provider_t* find_provider(const usage_rec_t* u, const char* arg) {
  for (uint8_t i = 0; i < u->count; i++)
    if (strncmp(u->p[i].id, arg, USAGE_ID_LEN) == 0) return &u->p[i];
  return nullptr;
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  usage_rec_t u = ds_get_usage();

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), &u.hdr, now_s())) {
    txt_set(s_name, "USAGE");
    txt_set(s_val, "--");
    txt_set(s_pct, sbuf);
    txt_color(s_pct, sv_severe(u.hdr.state) ? t->down : t->ink_dim);
    return;
  }

  char arg[COMP_ARG_LEN];
  bool has_arg = comp_arg("usage", arg, sizeof(arg));
  const usage_provider_t* p = has_arg ? find_provider(&u, arg) : nullptr;
  if (!p) {
    char up[COMP_ARG_LEN]; size_t k = 0;
    for (; has_arg && arg[k] && k + 1 < sizeof(up); k++) up[k] = (char)toupper((unsigned char)arg[k]);
    up[k] = '\0';
    txt_set(s_name, has_arg ? up : "USAGE");
    txt_set(s_val, "--");
    txt_set(s_pct, "not in list");
    txt_color(s_pct, t->ink_dim);
    return;
  }

  char up[USAGE_LABEL_LEN]; size_t k = 0;
  for (; p->label[k] && k + 1 < sizeof(up); k++) up[k] = (char)toupper((unsigned char)p->label[k]);
  up[k] = '\0';
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
