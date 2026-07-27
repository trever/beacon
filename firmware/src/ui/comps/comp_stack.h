#pragma once
#include <lvgl.h>
#include <stdbool.h>

// The Home complication stack: one root container holding one transparent container per resolved
// placement, rebuilt live when the hub pushes a new assignment
// (design docs/specs/2026-07-27-hub-app-and-home-complications-design.md §6.5, plan §4/§8).
//
// HEADER ONLY -- no comp_stack.cpp in this change; WS-1 implements it. This is the contract
// home_editorial.cpp (WS-1) builds against.

// Called from a view's build(): creates the stack's root container (a full-page, non-scrollable,
// styleless lv_obj_t so lv_obj_clean(root) tears down exactly the stack and nothing else -- the header
// and the prompt card live outside it) and the initial per-placement containers.
void comp_stack_build(lv_obj_t* page);

// Called from a view's update() (the existing 500 ms tick): walks the resolved list and calls each
// placement's comp_update_fn. Never creates an object -- only comp_stack_apply() does that.
void comp_stack_update(void);

// LVGL THREAD ONLY. Takes any pending assignment (comp_state_take_pending); no-ops (returns false) if
// none is pending or it equals the active list. Otherwise cleans the stack root, rebuilds it against the
// new list, calls comp_state_set_active, and calls comp_stack_update() once. Returns true iff it rebuilt.
// Must be gated on !s_settling by the caller (carousel.cpp) and must never be called from Core 0 -- this
// is the load-bearing risk in the whole design (§6.1/§10.1); see plan §8's exit gate.
bool comp_stack_apply(void);

// The permission-prompt takeover (home_editorial.cpp) hides the whole stack rather than tearing it down,
// so returning from the takeover is instant and does not re-trigger a rebuild.
void comp_stack_set_hidden(bool on);
