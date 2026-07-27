#include "ui/comps/comp_stack.h"
#include "ui/comps/comp_registry.h"
#include "core/comp_state.h"
#include "core/complications.h"
#include "config/layout.h"
#include "ui/styles.h"
#include "ui/screens/screen_common.h"   // hidden_set (diff-aware)
#include <string.h>

// The Home complication stack (plan §4 item 1). One root container per carousel lifetime -- only
// "home" exists (comp_state.cpp's COMP_FACES has one entry) -- holding one transparent container per
// resolved placement.
//
// `s_root` is created as a full-page (0,0)/SCREEN_W x SCREEN_H, styleless, non-scrollable child of the
// PAGE that home_editorial.cpp passes to comp_stack_build(). lv_obj_clean(s_root) therefore tears down
// exactly the stack's own containers -- the header and the prompt card are siblings built directly on
// the page by home_editorial.cpp, outside this subtree, and survive every rebuild untouched.
static lv_obj_t* s_root = nullptr;

// One entry per BUILT placement: the container plus which registry renderer (if any) owns it.
// comp_stack_update() walks this to call each placement's update() -- never creates an object here.
struct comp_slot_inst_t {
  lv_obj_t*              container;
  const complication_t*  def;   // NULL should not occur post-resolve, but stay defensive (see below)
};
static comp_slot_inst_t s_slots[COMP_SLOTS_MAX];
static uint8_t          s_slot_n = 0;

// size lives ONLY in COMP_CATALOG (plan §13 item 1) -- never re-derive or re-state it on complication_t.
static uint8_t catalog_size(const char* id) {
  for (uint8_t i = 0; i < COMP_CATALOG_N; i++)
    if (strcmp(COMP_CATALOG[i].id, id) == 0) return COMP_CATALOG[i].size;
  return 1;   // defensive; comp_list_resolve never hands back an id absent from the catalog
}

// Build one transparent container per placement in `list`, walking slot numbers n = 1.. as each
// placement consumes `size` units (design §5.3, plan §7's coordinate contract). The separator rule is
// the STACK's decision, not the renderer's: none at slot 1 (nothing above it to separate from -- a rule
// there would land in the header band), one at local y 0 everywhere else (plan §4 item 1).
static void build_containers(lv_obj_t* root, const comp_list_t* list) {
  s_slot_n = 0;
  uint8_t slot = 1;
  for (uint8_t i = 0; i < list->count && slot <= COMP_SLOTS_MAX && s_slot_n < COMP_SLOTS_MAX; i++) {
    const complication_t* def = comp_find(list->ids[i]);
    if (!def) continue;   // resolve should only hand back ids comp_find() answered non-NULL for

    uint8_t size = catalog_size(list->ids[i]);
    int top = comp_slot_anchor(slot) + COMP_BAND_TOP_DY;

    lv_obj_t* c = lv_obj_create(root);
    lv_obj_remove_style_all(c);
    lv_obj_clear_flag(c, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_clear_flag(c, LV_OBJ_FLAG_CLICKABLE);   // Phase 1 complications are not tappable (§5.6/§9.2)
    lv_obj_set_size(c, SCREEN_W - 2 * SAFE_INSET, COMP_SLOT_PITCH * size - 2);
    lv_obj_align(c, LV_ALIGN_TOP_LEFT, SAFE_INSET, top);

    if (slot != 1) {
      lv_obj_t* rule = lv_obj_create(c);
      lv_obj_remove_style_all(rule);
      lv_obj_add_style(rule, &S.hairline, 0);
      lv_obj_set_size(rule, SCREEN_W - 2 * SAFE_INSET, 1);
      lv_obj_align(rule, LV_ALIGN_TOP_LEFT, 0, 0);
    }

    def->build(c);

    s_slots[s_slot_n].container = c;
    s_slots[s_slot_n].def = def;
    s_slot_n++;
    slot = (uint8_t)(slot + size);
  }
}

void comp_stack_build(lv_obj_t* page) {
  s_root = lv_obj_create(page);
  lv_obj_remove_style_all(s_root);
  lv_obj_clear_flag(s_root, LV_OBJ_FLAG_SCROLLABLE);
  lv_obj_clear_flag(s_root, LV_OBJ_FLAG_CLICKABLE);
  lv_obj_set_size(s_root, SCREEN_W, SCREEN_H);
  lv_obj_align(s_root, LV_ALIGN_TOP_LEFT, 0, 0);

  comp_list_t active;
  comp_state_active(&active);
  build_containers(s_root, &active);
}

void comp_stack_update(void) {
  for (uint8_t i = 0; i < s_slot_n; i++)
    if (s_slots[i].def && s_slots[i].def->update) s_slots[i].def->update();
}

// LVGL THREAD ONLY (caller's job to guarantee -- carousel.cpp's tick_cb, gated on !s_settling). Takes
// any pending assignment; no-ops on nothing pending or an identical list (idempotence: the hub re-pushes
// the current assignment on every reconnect, and re-applying it must not flicker). This is the
// load-bearing risk in the whole design (§10.1) -- do not weaken any of the three guards: LVGL-thread
// only, !s_settling, no-op on equal.
bool comp_stack_apply(void) {
  // Home may not be built at all this boot (e.g. the user removed "home" from the active page list --
  // unlike "agents" it is not pinned). Leave the pending assignment untaken rather than discard it: NVS
  // already holds it (carousel_apply_comps persists before queuing), so nothing is lost -- a later boot
  // (page-list changes restart the device) picks it up fresh via load_active_comps(). This is just belt
  // and braces against lv_obj_clean(NULL); no currently-reachable path leaves s_root null once Home is
  // ever built.
  if (!s_root) return false;

  comp_list_t pending;
  if (!comp_state_take_pending(&pending)) return false;

  comp_list_t active;
  comp_state_active(&active);
  if (comp_list_equal(&pending, &active)) return false;

  lv_obj_clean(s_root);          // tears down exactly the stack's own children; s_root itself survives
  build_containers(s_root, &pending);
  comp_state_set_active(&pending);
  comp_stack_update();
  return true;
}

void comp_stack_set_hidden(bool on) {
  if (!s_root) return;
  hidden_set(s_root, on);
}
