// Home complication: ICE D4 RIN front-month contract (1 slot, owner "ice", no arg). Verbatim body-move
// of home_editorial.cpp's D4 RIN market row (plan §4 items 1/3) -- coordinate form changes from
// page-absolute to container-local; nothing else.
//
// build()/the live/status/trend update tail are shared with comp_fin via comp_common.h (convergence
// sweep, plan §10 item 1) -- both are shape-A rows with an identical value+trend contract; only the
// "no contracts" branch below (which comp_fin doesn't have -- it has "not configured" instead) differs.
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "ui/tick_flash.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "core/datastore.h"

static lv_obj_t *s_name, *s_val, *s_icon, *s_pct;
static tick_flash_t s_flash;

static void build(lv_obj_t* slot) {
  comp_build_shape_a(slot, "D4 RIN", &s_name, &s_val, &s_pct, &s_icon);
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

  // change_pct is ALREADY a percent from the wire -- comp_render_market_row feeds it straight to
  // fmt_change_num.
  comp_render_market_row(s_val, s_pct, s_icon, &s_flash, &ice.hdr, f->last, f->change_pct);
}

extern const complication_t comp_ice_reg = { "ice", "ice", "D4 RIN", build, update };
