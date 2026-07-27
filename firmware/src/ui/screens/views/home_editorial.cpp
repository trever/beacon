// Home -- host for the complication stack, plus the permission-prompt takeover.
//
// Home used to be a hand-laid page (clock + S&P + D4 RIN + Claude, in that fixed order). It is now a
// thin host: a header, the six-slot complication stack (ui/comps/comp_stack.h) that the hub assigns
// content to, and a hidden prompt card that takes the whole screen over when Coding Buddy has a pending
// permission prompt and the Agents page is not around to show it (design §4.6, plan §4).
//
// The row bodies that used to live here (clock/S&P/D4 RIN/Claude) moved VERBATIM into
// ui/comps/comp_clock.cpp, comp_fin.cpp, comp_ice.cpp, comp_agents.cpp -- see plan §7 for the coordinate
// contract that makes this refactor pixel-preserving (one intentional 4px move, nothing else).
#include "ui/screen.h"
#include "ui/screens/screen_common.h"
#include "ui/screens/views/prompt_card.h"
#include "ui/comps/comp_stack.h"
#include "ui/carousel.h"
#include "core/datastore.h"

static lv_obj_t*    s_slot;
static prompt_card_t s_prompt;

static void build(lv_obj_t* page) {
  s_slot = build_header(page, "HOME");
  comp_stack_build(page);
  prompt_card_build(page, &s_prompt);   // built ONCE; hidden until a takeover
  prompt_card_set_hidden(&s_prompt, true);
}

static void update(void) {
  buddy_rec_t b = ds_get_buddy();
  // Precedence on Home is takeover > stack, and nothing else pre-empts (design §4.6). A `question`
  // session never takes Home over -- no hook is held for AskUserQuestion (CONTRACT.md §C.3), so there
  // is no stall to fix here.
  bool takeover = b.prompt.present && !carousel_has_page("agents");
  comp_stack_set_hidden(takeover);
  prompt_card_set_hidden(&s_prompt, !takeover);
  if (takeover) prompt_card_update(&s_prompt, &b);
  else          comp_stack_update();
  // Header slot carries the hub-link state: it is the one source the user can act on (re-pair).
  slot_set(s_slot, "", &b.hdr, now_s());
}

extern const screen_view_t home_editorial_view = { build, update };
