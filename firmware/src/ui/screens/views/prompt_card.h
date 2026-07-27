#pragma once
// The Approve/Deny permission-prompt card (plan §4 item 5, design §4.6): extracted out of
// buddy_editorial.cpp so home_editorial.cpp's prompt takeover and the Agents screen share exactly ONE
// implementation of the layout, BUDDY_HIT_SLOP, the PROMPT_PENDING/PROMPT_SENT_OK/PROMPT_TOO_LATE kicker
// states, the (1 of N) queue badge, the expiry countdown, and the offline dimming.
//
// Header-only, `static inline` functions -- mirrors view_common.h's idiom (each including .cpp gets its
// own internal-linkage copy; no ODR issue). This header owns ONLY the widget set + how it displays a
// buddy_rec_t's prompt -- not where it sits on the page (each caller aligns its own instance) and NOT
// the decision logic: both callers route through the SAME buddy_decide()/buddy_dismiss() in hub_task.cpp
// (the single canonical guard, docs/recipes.md §5), so PROMPT_PENDING/PROMPT_SENT_OK/PROMPT_TOO_LATE
// behave identically everywhere this card is shown.
#include <lvgl.h>
#include <stdio.h>
#include "ui/screen.h"
#include "ui/styles.h"
#include "ui/theme.h"
#include "ui/screens/screen_common.h"
#include "core/datastore.h"
#include "core/hub_task.h"
#include "ui/idle_glue.h"
#include "config/layout.h"

typedef struct {
  lv_obj_t *kicker, *tool, *cmdbox, *cmd, *deny, *approve;
} prompt_card_t;

static inline void prompt_card_decide_cb(lv_event_t* e) {
  if (idle_take_wake_tap()) return;
  long approve = (long)lv_event_get_user_data(e);
  if (approve == 0 && buddy_dismiss()) return;   // deny doubles as dismiss for a "too late" warning
  buddy_decide(approve != 0);
}

static inline lv_obj_t* prompt_card_mk_btn(lv_obj_t* page, const char* txt, lv_align_t al, long approve) {
  lv_obj_t* b = lv_label_create(page); lv_obj_add_style(b, &S.display, 0);
  if (approve) lv_obj_add_style(b, &S.accent, 0);
  lv_label_set_text(b, txt);
  lv_obj_align(b, al, al == LV_ALIGN_BOTTOM_LEFT ? SAFE_INSET : -SAFE_INSET, -SAFE_INSET);
  lv_obj_add_flag(b, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_ext_click_area(b, BUDDY_HIT_SLOP);
  lv_obj_add_event_cb(b, prompt_card_decide_cb, LV_EVENT_CLICKED, (void*)approve);
  return b;
}

// Built ONCE by each caller (no object creation in update(), views/CONVENTIONS.md); toggle visibility
// with prompt_card_set_hidden().
static inline void prompt_card_build(lv_obj_t* page, prompt_card_t* c) {
  c->kicker = lv_label_create(page); lv_obj_add_style(c->kicker, &S.eyebrow, 0);
  lv_label_set_text(c->kicker, "PERMISSION -- APPROVE?");
  lv_obj_align(c->kicker, LV_ALIGN_LEFT_MID, SAFE_INSET, -80);

  c->tool = lv_label_create(page); lv_obj_add_style(c->tool, &S.display, 0);
  lv_obj_align(c->tool, LV_ALIGN_LEFT_MID, SAFE_INSET, -30);

  c->cmdbox = lv_obj_create(page); lv_obj_remove_style_all(c->cmdbox);
  lv_obj_set_size(c->cmdbox, SCREEN_W - 2 * SAFE_INSET, 56);
  lv_obj_align(c->cmdbox, LV_ALIGN_LEFT_MID, SAFE_INSET, 36);
  lv_obj_set_style_border_width(c->cmdbox, 1, 0);
  lv_obj_set_style_border_color(c->cmdbox, lv_color_hex(0x333333), 0);

  c->cmd = lv_label_create(c->cmdbox); lv_obj_add_style(c->cmd, &S.body, 0); lv_obj_center(c->cmd);

  c->deny    = prompt_card_mk_btn(page, "< DENY",    LV_ALIGN_BOTTOM_LEFT,  0);
  c->approve = prompt_card_mk_btn(page, "APPROVE >", LV_ALIGN_BOTTOM_RIGHT, 1);
}

static inline void prompt_card_set_hidden(prompt_card_t* c, bool hidden) {
  lv_obj_t* p[] = { c->kicker, c->tool, c->cmdbox, c->deny, c->approve };
  for (size_t i = 0; i < sizeof(p) / sizeof(p[0]); i++) hidden_set(p[i], hidden);
}

// Refresh the card from a buddy_rec_t's `prompt` (must be `present`; callers gate on that themselves --
// this function only renders, it does not decide whether a takeover/tier applies).
static inline void prompt_card_update(prompt_card_t* c, const buddy_rec_t* b) {
  const beacon_theme_t* t = theme_active();
  bool disabled = (b->hdr.state == ST_HUB_OFFLINE);
  txt_set(c->tool, b->prompt.tool);
  txt_set(c->cmd, b->prompt.hint);
  switch (b->prompt.decision_state) {
  case PROMPT_PENDING:   // sent; both actions dim until the truthful ack (issue #8).
    txt_set(c->kicker, "SENT -- AWAITING");
    txt_color(c->kicker, t->accent);
    txt_set(c->deny, "< DENY");
    txt_color(c->deny, t->ink_dim);
    txt_color(c->approve, t->ink_dim);
    break;
  case PROMPT_SENT_OK:   // applied; held briefly before the tick clears (issue #12).
    txt_set(c->kicker, "SENT OK");
    txt_color(c->kicker, t->up);
    txt_set(c->deny, "< DENY");
    txt_color(c->deny, t->ink_dim);
    txt_color(c->approve, t->ink_dim);
    break;
  case PROMPT_TOO_LATE:   // did not apply; deny becomes the dismiss affordance.
    txt_set(c->kicker, "TOO LATE -- DIDN'T APPLY");
    txt_color(c->kicker, t->down);
    txt_set(c->deny, "< DISMISS");
    txt_color(c->deny, t->ink);
    txt_color(c->approve, t->ink_dim);
    break;
  default: {
    char badge[16]; buddy_queue_badge(b->prompt.queue_len, badge, sizeof(badge));
    char eb[48];
    snprintf(eb, sizeof(eb), "PERMISSION -- APPROVE?%s %us",
             badge, (unsigned)buddy_prompt_secs_left(b, uptime_s()));
    txt_set(c->kicker, eb);
    txt_color(c->kicker, t->accent);
    txt_set(c->deny, "< DENY");
    txt_color(c->deny, t->ink_dim);
    // Dim approve when offline (hub can't relay the decision).
    txt_color(c->approve, disabled ? t->ink_dim : t->accent);
    break;
  }
  }
}
