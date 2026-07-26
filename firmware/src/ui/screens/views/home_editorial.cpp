// Home — at-a-glance dashboard.
//
// Clock over the three things worth a glance: the S&P, D4 RIN, and what Claude is doing.
// Deliberately NOT the weather panel this used to be -- temp/humidity were its only content and
// neither is why the device is on the desk.
//
// The rows source from DIFFERENT planes (Yahoo over WiFi, ICE over WiFi, the hub over BLE), so each
// resolves and renders against its own record header: one dead source must never blank the others.
//
// The market rows are value+trend; the Claude row is two lines (session label over what it is doing),
// following the VibeIsland card shape, because "which project, doing what" is the useful glance -- and
// because the 5h/7d usage percentages are unavailable on Claude Code Desktop (no statusline), so a
// percentage row would read "--" indefinitely.
#include "ui/screen.h"
#include "ui/fmt.h"
#include "ui/tick_flash.h"
#include "ui/fonts/icons.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/ice_common.h"
#include "core/datastore.h"
#include <string.h>

static lv_obj_t *s_slot, *s_clock, *s_merid, *s_date;

// Two market rows: name / value / trend-icon + percent.
#define MKT_ROWS 2
static lv_obj_t *s_mkt_val[MKT_ROWS], *s_mkt_icon[MKT_ROWS], *s_mkt_pct[MKT_ROWS];
static tick_flash_t s_mkt_flash[MKT_ROWS];

// Claude row: two lines, plus a leading state icon.
static lv_obj_t *s_cl_icon, *s_cl_line1, *s_cl_line2;

static void market_row(lv_obj_t* page, int i, int y, const char* name) {
  const beacon_theme_t* t = theme_active();

  lv_obj_t* nm = lv_label_create(page);
  lv_obj_add_style(nm, &S.slot, 0);
  lv_label_set_text(nm, name);
  lv_obj_align(nm, LV_ALIGN_TOP_LEFT, SAFE_INSET, y + 4);

  s_mkt_val[i] = lv_label_create(page);
  lv_obj_add_style(s_mkt_val[i], &S.display, 0);
  lv_label_set_text(s_mkt_val[i], "--");
  lv_obj_align(s_mkt_val[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y - 4);

  // Percent and its trend glyph are separate labels: the glyph is a PUA codepoint that only renders
  // in a lucide face (ui/fonts/icons.h), so it cannot share a label with the number.
  s_mkt_pct[i] = lv_label_create(page);
  lv_obj_add_style(s_mkt_pct[i], &S.slot, 0);
  lv_label_set_text(s_mkt_pct[i], "");
  lv_obj_align(s_mkt_pct[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y + 26);

  s_mkt_icon[i] = lv_label_create(page);
  lv_obj_set_style_text_font(s_mkt_icon[i], t->f_icon, 0);
  lv_obj_set_style_text_color(s_mkt_icon[i], t->ink_dim, 0);
  lv_label_set_text(s_mkt_icon[i], "");
  lv_obj_align_to(s_mkt_icon[i], s_mkt_pct[i], LV_ALIGN_OUT_LEFT_MID, -6, 0);

  lv_obj_t* rule = lv_obj_create(page);
  lv_obj_remove_style_all(rule);
  lv_obj_add_style(rule, &S.hairline, 0);
  lv_obj_set_size(rule, SCREEN_W - 2 * SAFE_INSET, 1);
  lv_obj_align(rule, LV_ALIGN_TOP_LEFT, SAFE_INSET, y - 14);
}

static void build(lv_obj_t* page) {
  const beacon_theme_t* t = theme_active();
  s_slot = build_header(page, "HOME");

  s_clock = lv_label_create(page);
  lv_obj_add_style(s_clock, &S.hero, 0);
  lv_label_set_text(s_clock, "--:--");
  lv_obj_align(s_clock, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 18);

  // Meridiem needs its own label: the hero face is a digit/symbol subset with no A-Z
  // (fonts/MANIFEST.md), so "AM"/"PM" cannot render in the clock itself.
  s_merid = lv_label_create(page);
  lv_obj_add_style(s_merid, &S.slot, 0);
  lv_label_set_text(s_merid, "");
  lv_obj_align_to(s_merid, s_clock, LV_ALIGN_OUT_RIGHT_BOTTOM, 8, -14);

  s_date = lv_label_create(page);
  lv_obj_add_style(s_date, &S.slot, 0);
  lv_label_set_text(s_date, "--");
  lv_obj_align(s_date, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 110);

  market_row(page, 0, SAFE_INSET + 152, "S&P 500");
  market_row(page, 1, SAFE_INSET + 214, "D4 RIN");

  // --- Claude block (two lines, VibeIsland-shaped) ---
  lv_obj_t* rule = lv_obj_create(page);
  lv_obj_remove_style_all(rule);
  lv_obj_add_style(rule, &S.hairline, 0);
  lv_obj_set_size(rule, SCREEN_W - 2 * SAFE_INSET, 1);
  lv_obj_align(rule, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 262);

  s_cl_icon = lv_label_create(page);
  lv_obj_set_style_text_font(s_cl_icon, t->f_icon, 0);
  lv_obj_set_style_text_color(s_cl_icon, t->ink_dim, 0);
  lv_label_set_text(s_cl_icon, ICON_BOT);
  lv_obj_align(s_cl_icon, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 280);

  // Line 1: the session -- "folder . branch", as the hub already formats it. Width-capped with a dot
  // ellipsis so a long label truncates instead of running past the safe area into the corner arc.
  s_cl_line1 = lv_label_create(page);
  lv_obj_add_style(s_cl_line1, &S.body, 0);
  lv_label_set_long_mode(s_cl_line1, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_cl_line1, SCREEN_W - 2 * SAFE_INSET - 30);
  lv_label_set_text(s_cl_line1, "--");
  lv_obj_align(s_cl_line1, LV_ALIGN_TOP_LEFT, SAFE_INSET + 26, SAFE_INSET + 276);

  // Line 2: state + age, dimmed -- the "doing what" line.
  s_cl_line2 = lv_label_create(page);
  lv_obj_add_style(s_cl_line2, &S.slot, 0);
  lv_label_set_long_mode(s_cl_line2, LV_LABEL_LONG_DOT);
  lv_obj_set_width(s_cl_line2, SCREEN_W - 2 * SAFE_INSET - 30);
  lv_label_set_text(s_cl_line2, "");
  lv_obj_align(s_cl_line2, LV_ALIGN_TOP_LEFT, SAFE_INSET + 26, SAFE_INSET + 306);
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

// One market row: value (flashing on a tick), trend icon, percent. A non-live source states WHY in
// the percent slot rather than showing a change that is no longer true.
static void market_put(int i, double value, const char* text, double pct, const record_hdr_t* h) {
  const beacon_theme_t* t = theme_active();
  bool live = (h->state == ST_LIVE);
  if (!live) tick_flash_reset(&s_mkt_flash[i]);   // don't flash on the link merely coming back

  txt_set(s_mkt_val[i], sv_placeholder(h->state) ? "--" : text);
  lv_color_t resting = sv_dim(h->state) ? t->ink_dim : t->ink;
  txt_color(s_mkt_val[i], live ? tick_flash_color(&s_mkt_flash[i], value, t, resting) : resting);

  char sbuf[24];
  if (sv_status(sbuf, sizeof(sbuf), h, now_s())) {
    txt_set(s_mkt_pct[i], sbuf);
    txt_color(s_mkt_pct[i], sv_severe(h->state) ? t->down : t->ink_dim);
    lv_label_set_text(s_mkt_icon[i], "");   // no trend claim while the source is not live
    return;
  }
  char pb[16];
  int dir = fmt_change_num(pb, sizeof(pb), pct);
  txt_set(s_mkt_pct[i], pb);
  lv_color_t dc = dir > 0 ? t->up : (dir < 0 ? t->down : t->ink_dim);
  txt_color(s_mkt_pct[i], dc);
  lv_label_set_text(s_mkt_icon[i], dir > 0 ? ICON_TREND_UP : (dir < 0 ? ICON_TREND_DOWN : ICON_FLAT));
  lv_obj_set_style_text_color(s_mkt_icon[i], dc, 0);
  lv_obj_align_to(s_mkt_icon[i], s_mkt_pct[i], LV_ALIGN_OUT_LEFT_MID, -6, 0);
}

// Session state -> icon + word. Mirrors DESIGN.md's session-row semantics: accent for the one that
// needs you, dim for merely-busy.
static const char* state_word(uint8_t st) {
  switch (st) {
    case BST_WORKING:        return "working";
    case BST_WAITING:        return "waiting";
    case BST_WAITING_QUEUED: return "queued";
    case BST_ATTENTION:      return "needs you";
    case BST_QUESTION:       return "asking";
    default:                 return "idle";
  }
}

static void update(void) {
  const beacon_theme_t* t = theme_active();
  render_clock_ex(s_clock, s_merid, s_date, "%a %d %b", txt_set);

  char v[32];

  // 1. S&P 500 (Yahoo, WiFi plane).
  finance_rec_t sp;
  if (finance_by_id("sp500", &sp)) {
    fmt_usd(v, sizeof(v), sp.value);
    market_put(0, sp.value, v, sp.change_pct, &sp.hdr);
  } else {
    // The hub can push a list without the S&P; say so instead of showing a stuck "--".
    txt_set(s_mkt_val[0], "--");
    txt_set(s_mkt_pct[0], "not in list");
    txt_color(s_mkt_pct[0], t->ink_dim);
    lv_label_set_text(s_mkt_icon[0], "");
  }

  // 2. D4 RIN front month (ICE, WiFi plane).
  ice_rec_t ice = ds_get_ice();
  const ice_contract_t* f = ice_front(&ice);
  if (f) {
    fmt_usd(v, sizeof(v), f->last);
    market_put(1, f->last, v, f->change_pct, &ice.hdr);
  } else {
    txt_set(s_mkt_val[1], "--");
    txt_set(s_mkt_pct[1], "no contracts");
    txt_color(s_mkt_pct[1], t->ink_dim);
    lv_label_set_text(s_mkt_icon[1], "");
  }

  // 3. Claude: the newest session, two lines. Sessions arrive newest-first from the hub.
  buddy_rec_t b = ds_get_buddy();
  if (b.hdr.state == ST_HUB_OFFLINE) {
    lv_label_set_text(s_cl_icon, ICON_BT_OFF);
    lv_obj_set_style_text_color(s_cl_icon, t->down, 0);
    txt_set(s_cl_line1, "hub offline");
    txt_color(s_cl_line1, t->ink_dim);
    char age[8]; age_str(age, sizeof(age), record_age_s(&b.hdr, now_s()));
    char l2[32]; snprintf(l2, sizeof(l2), "last synced %s ago", age);
    txt_set(s_cl_line2, l2);
    txt_color(s_cl_line2, t->ink_dim);
  } else if (b.session_count > 0) {
    const buddy_session_t* s = &b.sessions[0];
    bool attn = (s->state == BST_ATTENTION || s->state == BST_QUESTION);
    lv_label_set_text(s_cl_icon, attn ? ICON_ALERT : ICON_TERMINAL);
    lv_obj_set_style_text_color(s_cl_icon, attn ? t->accent : t->ink_dim, 0);
    txt_set(s_cl_line1, s->label[0] ? s->label : "claude");
    txt_color(s_cl_line1, t->ink);
    char age[8]; age_str(age, sizeof(age), s->ts ? (now_s() - s->ts) : UINT32_MAX);
    char l2[48];
    // running/waiting counts give the "and N others" context a single row cannot show.
    if (b.running > 1) snprintf(l2, sizeof(l2), "%s . %s . +%u more", state_word(s->state), age, (unsigned)(b.running - 1));
    else               snprintf(l2, sizeof(l2), "%s . %s", state_word(s->state), age);
    txt_set(s_cl_line2, l2);
    txt_color(s_cl_line2, attn ? t->accent : t->ink_dim);
  } else {
    lv_label_set_text(s_cl_icon, ICON_BOT);
    lv_obj_set_style_text_color(s_cl_icon, t->ink_dim, 0);
    txt_set(s_cl_line1, "no active sessions");
    txt_color(s_cl_line1, t->ink_dim);
    txt_set(s_cl_line2, "");
  }

  // Header slot carries the hub-link state: it is the one source the user can act on (re-pair).
  slot_set(s_slot, "", &b.hdr, now_s());
}

extern const screen_view_t home_editorial_view = { build, update };
