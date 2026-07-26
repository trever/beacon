// Home — at-a-glance dashboard.
//
// Clock over a compact list of the three things worth a glance: the S&P, D4 RIN, and Claude's 5h
// usage. Deliberately NOT the weather panel this used to be -- temp/humidity were its only content
// and neither is why the device is on the desk.
//
// Each row sources from a DIFFERENT plane (Yahoo over WiFi, ICE over WiFi, the hub over BLE), so each
// carries its own freshness and is resolved + rendered independently: one dead source must never blank
// the other two.
#include "ui/screen.h"
#include "ui/fmt.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "core/datastore.h"
#include <string.h>

static lv_obj_t *s_slot, *s_clock, *s_merid, *s_date;
#define HOME_ROWS 3
static lv_obj_t *s_val[HOME_ROWS], *s_sub[HOME_ROWS];

static void row(lv_obj_t* page, int i, int y, const char* name) {
  lv_obj_t* nm = lv_label_create(page);
  lv_obj_add_style(nm, &S.slot, 0);
  lv_label_set_text(nm, name);
  lv_obj_align(nm, LV_ALIGN_TOP_LEFT, SAFE_INSET, y + 6);

  s_val[i] = lv_label_create(page);
  lv_obj_add_style(s_val[i], &S.display, 0);
  lv_label_set_text(s_val[i], "--");
  lv_obj_align(s_val[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y);

  // Change / detail under the value, right-aligned, so the value column stays the single scan line.
  s_sub[i] = lv_label_create(page);
  lv_obj_add_style(s_sub[i], &S.slot, 0);
  lv_label_set_text(s_sub[i], "");
  lv_obj_align(s_sub[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y + 28);

  lv_obj_t* rule = lv_obj_create(page);
  lv_obj_remove_style_all(rule);
  lv_obj_add_style(rule, &S.hairline, 0);
  lv_obj_set_size(rule, SCREEN_W - 2 * SAFE_INSET, 1);
  lv_obj_align(rule, LV_ALIGN_TOP_LEFT, SAFE_INSET, y - 12);
}

static void build(lv_obj_t* page) {
  s_slot = build_header(page, "HOME");

  s_clock = lv_label_create(page);
  lv_obj_add_style(s_clock, &S.hero, 0);
  lv_label_set_text(s_clock, "--:--");
  lv_obj_align(s_clock, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 22);

  // Meridiem needs its own label: the hero face is a digit/symbol subset with no A-Z
  // (fonts/MANIFEST.md), so "AM"/"PM" cannot render in the clock itself.
  s_merid = lv_label_create(page);
  lv_obj_add_style(s_merid, &S.slot, 0);
  lv_label_set_text(s_merid, "");
  lv_obj_align_to(s_merid, s_clock, LV_ALIGN_OUT_RIGHT_BOTTOM, 8, -14);

  s_date = lv_label_create(page);
  lv_obj_add_style(s_date, &S.slot, 0);
  lv_label_set_text(s_date, "--");
  lv_obj_align(s_date, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 116);

  // 3 rows at 62px pitch from y=200: last rule+sub ends ~y=372, inside the 426 safe bottom.
  row(page, 0, SAFE_INSET + 160, "S&P 500");
  row(page, 1, SAFE_INSET + 222, "D4 RIN");
  row(page, 2, SAFE_INSET + 284, "CLAUDE");
}

// Locate a finance slot by its configured id. The list is hub-editable, so the S&P may sit at any
// index or be absent entirely -- never assume slot 0.
static bool finance_by_id(const char* id, finance_rec_t* out) {
  uint8_t n = ds_get_finance_count();
  for (uint8_t i = 0; i < n; i++) {
    finance_rec_t f = ds_get_finance(i);
    if (strncmp(f.id, id, FIN_ID_LEN) == 0) { *out = f; return true; }
  }
  return false;
}

// Render one row, honouring that record's own state. A non-live source states WHY in the sub slot
// rather than showing a change that is no longer true.
static void put(int i, const char* value, const char* sub, lv_color_t sub_col, const record_hdr_t* h) {
  const beacon_theme_t* t = theme_active();
  txt_set(s_val[i], sv_placeholder(h->state) ? "--" : value);
  txt_color(s_val[i], sv_dim(h->state) ? t->ink_dim : t->ink);
  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), h, now_s())) {
    txt_set(s_sub[i], sbuf);
    txt_color(s_sub[i], sv_severe(h->state) ? t->down : t->ink_dim);
  } else {
    txt_set(s_sub[i], sub);
    txt_color(s_sub[i], sub_col);
  }
}

static lv_color_t dir_color(const beacon_theme_t* t, int dir) {
  return dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  render_clock_ex(s_clock, s_merid, s_date, "%a %d %b", txt_set);

  char v[32], c[24];

  // 1. S&P 500 (Yahoo, WiFi plane).
  finance_rec_t sp;
  if (finance_by_id("sp500", &sp)) {
    fmt_usd(v, sizeof(v), sp.value);
    int dir = fmt_change(c, sizeof(c), sp.change_pct);
    put(0, v, c, dir_color(t, dir), &sp.hdr);
  } else {
    // The hub can push a list without the S&P; say so instead of showing a stuck "--".
    txt_set(s_val[0], "--");
    txt_set(s_sub[0], "not in list");
    txt_color(s_sub[0], t->ink_dim);
  }

  // 2. D4 RIN front month (ICE, WiFi plane).
  ice_rec_t ice = ds_get_ice();
  const ice_contract_t* f = ice_front(&ice);
  if (f) {
    fmt_usd(v, sizeof(v), f->last);
    int dir = fmt_change(c, sizeof(c), f->change_pct);
    put(1, v, c, dir_color(t, dir), &ice.hdr);
  } else {
    put(1, "--", "no contracts", t->ink_dim, &ice.hdr);
  }

  // 3. Claude 5h usage (hub, BLE plane). Resolved by provider id, not slot: the hub sends whichever
  // providers are toggled on, in its own display order.
  usage_rec_t u = ds_get_usage();
  const usage_provider_t* cp = NULL;
  for (uint8_t i = 0; i < u.count; i++)
    if (strncmp(u.p[i].id, "claude", USAGE_ID_LEN) == 0) { cp = &u.p[i]; break; }
  if (cp && cp->h5.pct >= 0) {
    snprintf(v, sizeof(v), "%d%%", (int)cp->h5.pct);
    char rs[12]; reset_str(rs, sizeof(rs), cp->h5.reset, now_s());
    snprintf(c, sizeof(c), "5H . %s", rs);
    put(2, v, c, t->ink_dim, &u.hdr);
  } else {
    // pct < 0 means unavailable, which is the honest reading when the hub has no usage source -- not 0%.
    put(2, "--", cp ? "unavailable" : "no hub", t->ink_dim, &u.hdr);
  }

  // Header slot carries the hub-link state: it is the one source the user can act on (re-pair).
  slot_set(s_slot, "", &u.hdr, now_s());
}

extern const screen_view_t home_editorial_view = { build, update };
