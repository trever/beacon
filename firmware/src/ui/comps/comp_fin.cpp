// Home complication: one finance instrument (1 slot, owner "markets"), selected by `arg` (a ticker id).
// Verbatim body-move of home_editorial.cpp's market_row/market_put/finance_by_id (plan §4 items 1/3) --
// the S&P-specific call site is gone because comp_fin is now generic and one-instance-per-id: it renders
// whichever ticker the hub assigns via comp_arg("fin", ...), the same finance_by_id scan today's Home
// does. NEVER assume slot 0 (plan's registry table) -- the list is hub-editable.
//
// build()/the live/status/trend update tail are shared with comp_ice via comp_common.h (convergence
// sweep, plan §10 item 1) -- both are shape-A rows with an identical value+trend contract; only the
// "not configured" branch below (which comp_ice doesn't have -- it has "no contracts" instead) differs.
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "core/comp_state.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/tick_flash.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"
#include <string.h>

static lv_obj_t *s_name, *s_val, *s_icon, *s_pct;
static tick_flash_t s_flash;

static void build(lv_obj_t* slot) {
  comp_build_shape_a(slot, "--", &s_name, &s_val, &s_pct, &s_icon);
}

static void update(void) {
  const beacon_theme_t* t = theme_active();

  char arg[COMP_ARG_LEN];
  bool has_arg = comp_arg("fin", arg, sizeof(arg));

  int idx = -1;
  uint8_t n = has_arg ? ds_get_finance_count() : 0;
  finance_rec_t f;
  for (uint8_t i = 0; i < n; i++) {
    f = ds_get_finance(i);
    if (strncmp(f.id, arg, FIN_ID_LEN) == 0) { idx = i; break; }
  }

  if (idx < 0) {
    // Not configured (no arg), or the configured id isn't in the hub's current ticker list -- say so
    // instead of showing a stuck "--" (generalizes today's Home's sp500-specific "not in list" case to
    // any ticker id).
    char up[COMP_ARG_LEN]; comp_str_upper(up, sizeof(up), has_arg ? arg : "");
    txt_set(s_name, has_arg ? up : "FIN");
    txt_set(s_val, "--");
    txt_set(s_pct, "not in list");
    txt_color(s_pct, t->ink_dim);
    lv_label_set_text(s_icon, "");
    return;
  }

  txt_set(s_name, fin_name(idx, f));
  comp_render_market_row(s_val, s_pct, s_icon, &s_flash, &f.hdr, f.value, f.change_pct);
}

extern const complication_t comp_fin_reg = { "fin", "markets", "Market", build, update };
