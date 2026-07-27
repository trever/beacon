#include "ui/screen.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/view_common.h"
#include "ui/screens/views/prompt_card.h"
#include "ui/theme.h"
#include "core/datastore.h"
#include "core/hub_task.h"
#include "ui/idle_glue.h"
#include "ui/fonts/icons.h"

#define SESSION_ROWS    4
#define SESSION_ROW_H  64
#define SESSION_LIST_Y (SAFE_INSET + 72)
// Tick heights: SHORT brackets the folder line; TALL spans down to the branch line.
#define TICK_SHORT      22
#define TICK_TALL       42
// Gutter the agent glyph sits in, before the row's two text lines.
#define ROW_TEXT_X      26

static lv_obj_t *s_slot, *s_status;
static prompt_card_t s_card;   // the Approve/Deny card (views/prompt_card.h) -- shared with home_editorial.cpp
static lv_obj_t *s_row_folder[SESSION_ROWS];
static lv_obj_t *s_row_sub[SESSION_ROWS];
static lv_obj_t *s_row_tick[SESSION_ROWS];
static lv_obj_t *s_row_state[SESSION_ROWS];
static lv_obj_t *s_row_age[SESSION_ROWS];
static lv_obj_t *s_row_btn[SESSION_ROWS];   // transparent tap target (issue #110 Phase 2)
static lv_obj_t *s_row_icon[SESSION_ROWS];  // agent glyph (lucide), tinted by session state
static lv_obj_t *s_q_btn, *s_q_badge;
static uint8_t   s_q_session_idx;

static void update(void);

static void on_question_tap(lv_event_t* e) {
  (void)e;
  if (idle_take_wake_tap()) return;
  buddy_rec_t b = ds_get_buddy();
  if (s_q_session_idx < b.session_count &&
      b.sessions[s_q_session_idx].state == BST_QUESTION) {
    buddy_open(b.sessions[s_q_session_idx].id);
    update();
  }
}

static void on_row_tap(lv_event_t* e) {
  if (idle_take_wake_tap()) return;
  uint8_t idx = (uint8_t)(uintptr_t)lv_event_get_user_data(e);
  buddy_rec_t b = ds_get_buddy();
  if (idx < b.session_count) buddy_open(b.sessions[idx].id);
}

static void build(lv_obj_t* page) {
  s_slot = build_header(page, "AGENTS");
  s_status = lv_label_create(page); lv_obj_add_style(s_status, &S.slot, 0);
  lv_obj_align(s_status, LV_ALIGN_TOP_LEFT, SAFE_INSET, SAFE_INSET + 26);
  prompt_card_build(page, &s_card);

  for (uint8_t i = 0; i < SESSION_ROWS; i++) {
    lv_coord_t y = SESSION_LIST_Y + (lv_coord_t)(i * SESSION_ROW_H);

    // Transparent tap button created first (below labels in z-order) — issue #110 Phase 2.
    s_row_btn[i] = lv_obj_create(page);
    lv_obj_remove_style_all(s_row_btn[i]);
    lv_obj_set_size(s_row_btn[i], SCREEN_W - 2 * SAFE_INSET, SESSION_ROW_H);
    lv_obj_align(s_row_btn[i], LV_ALIGN_TOP_LEFT, SAFE_INSET, y);
    lv_obj_set_style_bg_opa(s_row_btn[i], LV_OPA_TRANSP, 0);
    lv_obj_add_flag(s_row_btn[i], LV_OBJ_FLAG_CLICKABLE);
    lv_obj_clear_flag(s_row_btn[i], LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_event_cb(s_row_btn[i], on_row_tap, LV_EVENT_CLICKED, (void*)(uintptr_t)i);

    // 2px editorial tick (thinner than others to match the editorial hairline idiom);
    // top-anchored to the folder line. Height set per row in update()
    // (TICK_SHORT = folder line only; TICK_TALL = spans down to the branch line).
    s_row_tick[i] = lv_obj_create(page);
    lv_obj_remove_style_all(s_row_tick[i]);
    lv_obj_set_size(s_row_tick[i], 2, TICK_SHORT);
    lv_obj_set_style_bg_opa(s_row_tick[i], LV_OPA_COVER, 0);
    lv_obj_set_style_bg_color(s_row_tick[i], lv_color_hex(0x444444), 0);
    lv_obj_set_style_radius(s_row_tick[i], 0, 0);

    // Agent glyph. Its own label in the icons face: the lucide glyphs live at PUA codepoints that the
    // text faces do not carry, so a mixed string would render a box (fonts/MANIFEST.md).
    s_row_icon[i] = lv_label_create(page);
    lv_label_set_text(s_row_icon[i], "");
    lv_obj_set_style_text_font(s_row_icon[i], theme_active()->f_icon, 0);
    lv_obj_align(s_row_icon[i], LV_ALIGN_TOP_LEFT, SAFE_INSET + 10, y + 2);

    // Folder: display style (large serif weight), left of meta block.
    s_row_folder[i] = lv_label_create(page);
    lv_label_set_text(s_row_folder[i], "");
    lv_obj_add_style(s_row_folder[i], &S.slot, 0);
    lv_obj_set_width(s_row_folder[i], SCREEN_W - 2 * SAFE_INSET - 10 - 90 - ROW_TEXT_X);
    lv_label_set_long_mode(s_row_folder[i], LV_LABEL_LONG_DOT);
    lv_obj_align(s_row_folder[i], LV_ALIGN_TOP_LEFT, SAFE_INSET + 10 + ROW_TEXT_X, y);
    // Top-align the tick to the folder line; small +y nudge brackets the folder cap-height.
    lv_obj_align_to(s_row_tick[i], s_row_folder[i], LV_ALIGN_OUT_LEFT_TOP, -8, 4);

    // Branch (sub-line): slot style, dim.
    s_row_sub[i] = lv_label_create(page);
    lv_label_set_text(s_row_sub[i], "");
    lv_obj_add_style(s_row_sub[i], &S.slot, 0);
    lv_obj_set_style_text_color(s_row_sub[i], lv_color_hex(0x666666), 0);
    lv_obj_set_width(s_row_sub[i], SCREEN_W - 2 * SAFE_INSET - 10 - 90 - ROW_TEXT_X);
    lv_label_set_long_mode(s_row_sub[i], LV_LABEL_LONG_DOT);
    lv_obj_align(s_row_sub[i], LV_ALIGN_TOP_LEFT, SAFE_INSET + 10 + ROW_TEXT_X, y + 26);

    // State word (right, top) — uppercase for editorial.
    s_row_state[i] = lv_label_create(page);
    lv_label_set_text(s_row_state[i], "");
    lv_obj_add_style(s_row_state[i], &S.slot, 0);
    lv_obj_set_width(s_row_state[i], 88);
    lv_label_set_long_mode(s_row_state[i], LV_LABEL_LONG_DOT);
    lv_obj_align(s_row_state[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y);

    // Age (right, below state word) — slot style, dim.
    s_row_age[i] = lv_label_create(page);
    lv_label_set_text(s_row_age[i], "");
    lv_obj_add_style(s_row_age[i], &S.slot, 0);
    lv_obj_set_style_text_color(s_row_age[i], lv_color_hex(0x666666), 0);
    lv_obj_set_width(s_row_age[i], 88);
    lv_label_set_long_mode(s_row_age[i], LV_LABEL_LONG_DOT);
    lv_obj_align(s_row_age[i], LV_ALIGN_TOP_RIGHT, -SAFE_INSET, y + 26);
  }

  s_q_btn = lv_btn_create(page);
  lv_obj_remove_style_all(s_q_btn);
  lv_obj_set_size(s_q_btn, lv_pct(100), lv_pct(100));
  lv_obj_align(s_q_btn, LV_ALIGN_TOP_LEFT, 0, 0);
  lv_obj_add_flag(s_q_btn, LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_event_cb(s_q_btn, on_question_tap, LV_EVENT_CLICKED, NULL);

  const beacon_theme_t* t = theme_active();
  s_q_badge = lv_label_create(page);
  lv_obj_set_style_text_font(s_q_badge, t->f_mono, 0);
  lv_obj_set_style_text_color(s_q_badge, t->ink_dim, 0);
  lv_label_set_text(s_q_badge, "");
  lv_obj_align(s_q_badge, LV_ALIGN_TOP_RIGHT, -SAFE_INSET, SAFE_INSET);
  lv_obj_add_flag(s_q_badge, LV_OBJ_FLAG_HIDDEN);
}

static void show_prompt(bool on) {
  prompt_card_set_hidden(&s_card, !on);
  for (uint8_t i = 0; i < SESSION_ROWS; i++) {
    if (on) {
      lv_obj_add_flag(s_row_btn[i],     LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_tick[i],    LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_folder[i],  LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_sub[i],     LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_state[i],   LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_age[i],     LV_OBJ_FLAG_HIDDEN);
    } else {
      lv_obj_clear_flag(s_row_btn[i],   LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(s_row_tick[i],   LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(s_row_folder[i], LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(s_row_sub[i],    LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(s_row_state[i],  LV_OBJ_FLAG_HIDDEN);
      lv_obj_clear_flag(s_row_age[i],    LV_OBJ_FLAG_HIDDEN);
    }
  }
}

static void update(void) {
  buddy_rec_t b = ds_get_buddy(); uint32_t now = now_s();
  slot_set(s_slot, "REQ --", &b.hdr, now);
  txt_fmt(s_status, "%u RUN . %u WAIT",
    b.running, b.waiting);
  bool disabled = (b.hdr.state == ST_HUB_OFFLINE);

  // Find newest QUESTION session.
  int8_t q_idx = -1;
  uint8_t q_count = 0;
  for (uint8_t i = 0; i < b.session_count; i++) {
    if (b.sessions[i].state == BST_QUESTION) {
      if (q_idx < 0) q_idx = (int8_t)i;
      q_count++;
    }
  }

  lv_obj_add_flag(s_q_btn,   LV_OBJ_FLAG_HIDDEN);
  lv_obj_add_flag(s_q_badge, LV_OBJ_FLAG_HIDDEN);

  if (b.prompt.present) {
    // TIER 1: permission prompt card. Rendered even when offline; approve is dimmed when locked
    // (matching calm/hud which dim actions rather than hiding the entire takeover). All the
    // PROMPT_PENDING/PROMPT_SENT_OK/PROMPT_TOO_LATE display logic now lives in prompt_card.h, shared
    // verbatim with home_editorial.cpp's takeover.
    show_prompt(true);
    prompt_card_update(&s_card, &b);
  } else if (q_idx >= 0) {
    // TIER 2: question card — reuses the prompt-card widgets directly (not prompt_card_update(), which
    // is shaped for a permission prompt); deny/approve hidden.
    s_q_session_idx = (uint8_t)q_idx;
    const buddy_session_t* qs = &b.sessions[q_idx];
    const beacon_theme_t* t = theme_active();

    show_prompt(true);
    lv_obj_add_flag(s_card.deny,    LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(s_card.approve, LV_OBJ_FLAG_HIDDEN);

    txt_set(s_card.kicker, "YOUR TURN");
    txt_color(s_card.kicker, t->accent);

    char folder[BUDDY_LABEL_LEN], branch[BUDDY_LABEL_LEN];
    buddy_session_split_label(qs->label, folder, sizeof(folder), branch, sizeof(branch));
    txt_set(s_card.tool, folder[0] ? folder : qs->id);

    char hintbuf[BUDDY_LABEL_LEN + 24];
    if (branch[0])
      snprintf(hintbuf, sizeof(hintbuf), "%s\nTAP TO ANSWER ON MAC", branch);
    else
      snprintf(hintbuf, sizeof(hintbuf), "TAP TO ANSWER ON MAC");
    txt_set(s_card.cmd, hintbuf);

    // Open-state feedback overrides the eyebrow.
    if (b.open_state != OPEN_NONE &&
        strncmp(b.open_id, qs->id, BUDDY_SID_LEN) == 0) {
      if (b.open_state == OPEN_SENDING) {
        txt_set(s_card.kicker, "OPENING...");
        txt_color(s_card.kicker, t->accent);
      } else if (b.open_state == OPEN_OK) {
        txt_set(s_card.kicker, "OPENED");
        txt_color(s_card.kicker, t->up);
      } else {
        txt_set(s_card.kicker, "COULDN'T OPEN");
        txt_color(s_card.kicker, t->down);
      }
    }

    if (q_count > 1) {
      char badge[16]; snprintf(badge, sizeof(badge), "(1 OF %u)", (unsigned)q_count);
      lv_label_set_text(s_q_badge, badge);
      lv_obj_clear_flag(s_q_badge, LV_OBJ_FLAG_HIDDEN);
    }
    lv_obj_clear_flag(s_q_btn, LV_OBJ_FLAG_HIDDEN);
  } else {
    // TIER 3: session list (unchanged).
    show_prompt(false);
    const beacon_theme_t* t = theme_active();

    if (disabled) {
      // Hub offline: show "OFFLINE" label and ensure all row tap buttons are non-clickable.
      for (uint8_t i = 0; i < SESSION_ROWS; i++) {
        lv_obj_add_flag(s_row_btn[i],  LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_row_tick[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_row_icon[i], LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_row_folder[i], i == 0 ? "OFFLINE" : "");
        lv_label_set_text(s_row_sub[i],    "");
        lv_label_set_text(s_row_state[i],  "");
        lv_label_set_text(s_row_age[i],    "");
      }
      lv_obj_set_style_text_color(s_row_folder[0], lv_color_hex(0x666666), 0);
      return;
    }

    uint8_t n = (b.session_count < SESSION_ROWS) ? b.session_count : SESSION_ROWS;

    if (n == 0) {
      lv_obj_add_flag(s_row_btn[0],  LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_tick[0], LV_OBJ_FLAG_HIDDEN);
      lv_obj_add_flag(s_row_icon[0], LV_OBJ_FLAG_HIDDEN);
      lv_label_set_text(s_row_folder[0], "IDLE");
      lv_obj_set_style_text_color(s_row_folder[0], lv_color_hex(0x666666), 0);
      lv_label_set_text(s_row_sub[0], "");
      lv_label_set_text(s_row_state[0], "");
      lv_label_set_text(s_row_age[0], "");
      for (uint8_t i = 1; i < SESSION_ROWS; i++) {
        lv_obj_add_flag(s_row_btn[i],  LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_row_tick[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_row_icon[i], LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_row_folder[i], "");
        lv_label_set_text(s_row_sub[i], "");
        lv_label_set_text(s_row_state[i], "");
        lv_label_set_text(s_row_age[i], "");
      }
    } else {
      for (uint8_t i = 0; i < SESSION_ROWS; i++) {
        if (i < n) {
          const buddy_session_t* s = &b.sessions[i];
          lv_obj_clear_flag(s_row_btn[i], LV_OBJ_FLAG_HIDDEN);

          char folder[BUDDY_LABEL_LEN], branch[BUDDY_LABEL_LEN];
          buddy_session_split_label(s->label, folder, sizeof(folder), branch, sizeof(branch));

          char age[12];
          buddy_session_age(s->ts, age, sizeof(age));

          // Tick color by state.
          // The tick brackets whatever the row actually shows: line 2 is now the message (branch only
          // when an older hub sends no detail), so keying off the branch alone would stop it short.
          bool has_branch = (s->msg[0] != '\0') || (branch[0] != '\0');
          lv_color_t tick_col = buddy_session_state_color(t, s->state);
          lv_obj_set_style_bg_color(s_row_tick[i], tick_col, 0);
          lv_obj_set_height(s_row_tick[i], has_branch ? TICK_TALL : TICK_SHORT);
          lv_obj_clear_flag(s_row_tick[i], LV_OBJ_FLAG_HIDDEN);

          // Line 1: "project - title" from the sdetail frame; line 2: the newest message. Both fall back
          // to the sessions frame's "folder | branch" label, which is all an older hub sends.
          const char* proj  = s->project[0] ? s->project : (folder[0] ? folder : s->id);
          char head[BUDDY_PROJECT_LEN + BUDDY_TITLE_LEN + 4];
          if (s->title[0]) snprintf(head, sizeof(head), "%s - %s", proj, s->title);
          else             snprintf(head, sizeof(head), "%s", proj);
          lv_label_set_text(s_row_folder[i], head);
          lv_obj_set_style_text_color(s_row_folder[i], t->ink, 0);

          lv_label_set_text(s_row_sub[i], s->msg[0] ? s->msg : branch);

          // Agent glyph, tinted by state so "needs you" reads at a glance without parsing the word.
          lv_label_set_text(s_row_icon[i],
                            (s->agent[0] && strcmp(s->agent, "claude") != 0) ? ICON_TERMINAL : ICON_BOT);
          lv_obj_set_style_text_color(s_row_icon[i], buddy_session_state_color(t, s->state), 0);
          lv_obj_clear_flag(s_row_icon[i], LV_OBJ_FLAG_HIDDEN);

          // State word: open feedback overrides, else UPPERCASE for editorial.
          if (b.open_state != OPEN_NONE &&
              strncmp(b.open_id, s->id, BUDDY_SID_LEN) == 0) {
            if (b.open_state == OPEN_SENDING) {
              lv_label_set_text(s_row_state[i], "OPENING...");
              lv_obj_set_style_text_color(s_row_state[i], lv_color_hex(0x666666), 0);
            } else if (b.open_state == OPEN_OK) {
              lv_label_set_text(s_row_state[i], "OPENED");
              lv_obj_set_style_text_color(s_row_state[i], t->up, 0);
            } else {
              lv_label_set_text(s_row_state[i], "COULDN'T");
              lv_obj_set_style_text_color(s_row_state[i], t->down, 0);
            }
          } else {
            const char* sw = buddy_session_state_word(s->state);
            char sw_up[16];
            size_t k = 0;
            for (; sw[k] && k < sizeof(sw_up) - 1; k++) sw_up[k] = (char)toupper((unsigned char)sw[k]);
            sw_up[k] = '\0';
            lv_label_set_text(s_row_state[i], sw_up);
            lv_color_t sc;
            if (s->state == BST_ATTENTION)     sc = t->accent;
            else if (s->state == BST_WAITING)  sc = t->down;
            else                               sc = lv_color_hex(0x666666);
            lv_obj_set_style_text_color(s_row_state[i], sc, 0);
          }

          // Age.
          lv_label_set_text(s_row_age[i], age);
        } else {
          lv_obj_add_flag(s_row_btn[i],  LV_OBJ_FLAG_HIDDEN);
          lv_obj_add_flag(s_row_tick[i], LV_OBJ_FLAG_HIDDEN);
          lv_obj_add_flag(s_row_icon[i], LV_OBJ_FLAG_HIDDEN);
          lv_label_set_text(s_row_folder[i], "");
          lv_label_set_text(s_row_sub[i], "");
          lv_label_set_text(s_row_state[i], "");
          lv_label_set_text(s_row_age[i], "");
        }
      }
    }
  }
}

extern const screen_view_t buddy_editorial_view = { build, update };
