#pragma once
#include "core/page_config.h"
#include "core/complications.h"
#include <lvgl.h>

// Builds the swipe carousel from the five screen modules + the dot indicator, applies the initial
// theme, and starts the ~500 ms visible-screen update timer. Call after styles_init() + datastore_init().
void carousel_init(void);
int  carousel_current(void);     // current page index
lv_obj_t* carousel_root(void);   // the pager object (dev_seed attaches the long-press fault-injector here)
void carousel_set_swipe_enabled(bool en);   // suspend/restore horizontal swipe (e.g. while an overlay is open)
void carousel_set_tick_paused(bool paused);  // pause/resume the 500ms update tick (idle sleep, #60)
// (Re)arm auto-rotate from the persisted interval (NVS_ROTATE_KEY). Call after changing the setting;
// carousel_init() calls it once at boot. Safe to call repeatedly.
void carousel_apply_rotate(void);
void carousel_goto_buddy(void);              // navigate to the CLAUDE/buddy screen (auto-wake, no animation)

// Apply a hub-supplied page list: resolve against the registry, persist to NVS, and report the resolved
// count (0 => rejected, nothing written). `changed` is false when the list already matches what is
// running -- the hub re-pushes on every reconnect, and restarting for an identical list would loop
// forever. Restart only when `changed`.
uint8_t carousel_apply_pages(const page_list_t* want, bool* changed);

// Apply a hub-supplied complication assignment for the "home" face: resolve against the renderers this
// firmware actually has (comp_find()), persist to NVS, queue it for the LVGL tick to pick up, and report
// the resolved PLACEMENT count (0 is legitimate for an explicit-empty request; see comp_list_resolve rule
// 5). `changed` is false when the resolved list already matches the active one -- the hub re-pushes on
// every reconnect, and queuing an identical rebuild would flicker Home for nothing. Unlike pages, this
// never restarts: the caller (hub_task.cpp's on_comps) applies live via comp_stack_apply() on the next
// tick (plan §4/§8).
uint8_t carousel_apply_comps(const comp_list_t* want, bool explicit_empty, bool* changed);

// Read one option of an ACTIVE page ("chart", "sym", ...). False (and empty `out`) when the page is not
// in the active set or carries no such option. Screens call this instead of reading NVS themselves.
bool carousel_page_opt(const char* page_id, const char* key, char* out, size_t cap);

// True when `id` is in the active page list (a three-line export of the existing active_index_of()).
// Home's permission-prompt takeover uses this to ask "is Agents where the user can already see this?"
bool carousel_has_page(const char* id);
void carousel_advance(int dir);              // +1 next / -1 prev page, animated (physical buttons)
#if BEACON_CAPTURE
int  carousel_count(void);                   // number of screens (screenshot sweep)
const char* carousel_screen_id(int idx);     // canonical id of screen idx (screenshot filenames)
void carousel_goto(int idx);                 // make screen idx the visible/active page (no animation)
#endif
