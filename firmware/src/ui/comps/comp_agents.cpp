// Home complication: the Claude/agents block (1 slot, owner "agents", no arg): icon + newest session's
// "project - title" / "state . age [. +N more]". Verbatim body-move of home_editorial.cpp's Claude block
// (plan §4 items 3/7) with exactly ONE intentional change: line 2 moves from container-local y 44 (today's
// SAFE_INSET+306 = a+30, a 64px span that only worked by being the last row) to local y 40, matching the
// value row's secondary baseline (plan §7 / design §5.2). Everything else is coordinate FORM only:
// page-absolute becomes container-local. build() is shared with comp_sonos via comp_common.h
// (convergence sweep, plan §10 item 1): both are shape-B rows (icon + two lines).
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_common.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/fonts/icons.h"
#include "ui/styles.h"
#include "ui/state_view.h"
#include "config/layout.h"
#include "core/datastore.h"
#include <string.h>

static lv_obj_t *s_icon, *s_line1, *s_line2;

static void build(lv_obj_t* slot) {
  comp_build_shape_b(slot, ICON_BOT, &s_icon, &s_line1, &s_line2);
}

// Session state -> word. Mirrors DESIGN.md's session-row semantics: accent for the one that needs you,
// dim for merely-busy.
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
  buddy_rec_t b = ds_get_buddy();

  if (b.hdr.state == ST_HUB_OFFLINE) {
    lv_label_set_text(s_icon, ICON_BT_OFF);
    lv_obj_set_style_text_color(s_icon, t->down, 0);
    txt_set(s_line1, "hub offline");
    txt_color(s_line1, t->ink_dim);
    char age[8]; age_str(age, sizeof(age), record_age_s(&b.hdr, now_s()));
    char l2[32]; snprintf(l2, sizeof(l2), "last synced %s ago", age);
    txt_set(s_line2, l2);
    txt_color(s_line2, t->ink_dim);
  } else if (b.session_count > 0) {
    const buddy_session_t* s = &b.sessions[0];
    bool attn = (s->state == BST_ATTENTION || s->state == BST_QUESTION);
    lv_label_set_text(s_icon, attn ? ICON_ALERT : ICON_TERMINAL);
    lv_obj_set_style_text_color(s_icon, attn ? t->accent : t->ink_dim, 0);
    // Prefer the sdetail frame's "project - title"; fall back to the sessions label for an older hub.
    char head[BUDDY_PROJECT_LEN + BUDDY_TITLE_LEN + 4];
    if (s->project[0] && s->title[0])      snprintf(head, sizeof(head), "%s - %s", s->project, s->title);
    else if (s->project[0])                snprintf(head, sizeof(head), "%s", s->project);
    else                                   snprintf(head, sizeof(head), "%s", s->label[0] ? s->label : "claude");
    txt_set(s_line1, head);
    txt_color(s_line1, t->ink);
    char age[8]; age_str(age, sizeof(age), s->ts ? (now_s() - s->ts) : UINT32_MAX);
    char l2[48];
    // running/waiting counts give the "and N others" context a single row cannot show.
    if (b.running > 1) snprintf(l2, sizeof(l2), "%s . %s . +%u more", state_word(s->state), age, (unsigned)(b.running - 1));
    else               snprintf(l2, sizeof(l2), "%s . %s", state_word(s->state), age);
    txt_set(s_line2, l2);
    txt_color(s_line2, attn ? t->accent : t->ink_dim);
  } else {
    lv_label_set_text(s_icon, ICON_BOT);
    lv_obj_set_style_text_color(s_icon, t->ink_dim, 0);
    txt_set(s_line1, "no active sessions");
    txt_color(s_line1, t->ink_dim);
    txt_set(s_line2, "");
  }
}

extern const complication_t comp_agents_reg = { "agents", "agents", "Agents", build, update };
