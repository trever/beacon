#include "ui/carousel.h"
#include "ui/carousel_nav.h"
#include "ui/screen.h"
#include "ui/styles.h"
#include "ui/theme.h"
#include "ui/theme_catalog.h"
#include "ui/chrome.h"
#include "ui/durations.h"
#include "ui/idle_glue.h"
#include "core/nvs.h"
#include "core/page_config.h"
#include "core/complications.h"
#include "core/comp_state.h"
#include "ui/comps/comp_registry.h"
#include "ui/comps/comp_stack.h"
#include <string.h>
#include "util/log.h"
#include "config/layout.h"
#include "ui/screens/screen_home.h"
#include "ui/screens/screen_finance.h"
#include "ui/screens/screen_ice.h"
#include "ui/screens/screen_chart.h"
#include "ui/screens/screen_buddy.h"
#include "ui/screens/screen_sonos.h"
#include "ui/screens/screen_settings.h"

// Every screen this firmware carries, keyed by the STABLE ID the hub uses on the wire. Which of these
// appear, and in what order, is chosen on the hub and persisted in NVS -- see core/page_config.h.
// Screens stay compiled in (flash is ~56% of 3 MB); the hub only selects and orders them.
typedef struct { const char* id; const screen_module_t* mod; } page_entry_t;
static const page_entry_t REGISTRY[] = {
  {"home",     &home_module},
  {"markets",  &finance_module},
  {"chart",    &chart_module},
  {"ice",      &ice_module},
  {"agents",   &buddy_module},
  {"sonos",    &sonos_module},
  {"settings", &settings_module},
};
static const uint8_t REGISTRY_N = (uint8_t)(sizeof(REGISTRY) / sizeof(REGISTRY[0]));

// Shipped default when NVS is empty or holds nothing usable. Markets is deliberately absent.
static const char* DEFAULT_PAGES = "home,chart,ice,agents,settings";
#define PAGE_ALWAYS_ID "settings"   // pinned so no config can strand the user without settings
#define NVS_PAGES_KEY  "pages"

// The resolved, active page set. MODULES/COUNT are now runtime state, not compile-time constants.
static const screen_module_t* MODULES[PAGES_MAX];
static char  s_active_ids[PAGES_MAX][PAGE_ID_LEN];
static char  s_active_opts[PAGES_MAX][PAGE_OPTS_LEN];
static int   COUNT = 0;

static const screen_module_t* registry_lookup(const char* id) {
  for (uint8_t i = 0; i < REGISTRY_N; i++)
    if (strcmp(REGISTRY[i].id, id) == 0) return REGISTRY[i].mod;
  return nullptr;
}

// Resolve the persisted (or hub-supplied) list into MODULES/COUNT.
static void load_active_pages(void) {
  const char* known[REGISTRY_N];
  for (uint8_t i = 0; i < REGISTRY_N; i++) known[i] = REGISTRY[i].id;

  // Stored as the comma-joined id string via the generic bytes API (nvs.h has no string helper).
  char stored[PAGES_MAX * PAGE_ID_LEN] = {0};
  size_t n = nvs_get_bytes(NVS_PAGES_KEY, stored, sizeof(stored) - 1);
  stored[n < sizeof(stored) ? n : sizeof(stored) - 1] = '\0';
  if (n == 0) snprintf(stored, sizeof(stored), "%s", DEFAULT_PAGES);

  page_list_t want, fallback, resolved;
  page_list_deserialize(stored, &want);
  page_list_deserialize(DEFAULT_PAGES, &fallback);
  page_list_resolve(&want, known, REGISTRY_N, PAGE_ALWAYS_ID, &fallback, &resolved);

  COUNT = 0;
  for (uint8_t i = 0; i < resolved.count; i++) {
    const screen_module_t* m = registry_lookup(resolved.ids[i]);
    if (!m) continue;                      // resolve already filtered, belt and braces
#if BEACON_FORCE_NO_AGENTS
    if (strcmp(resolved.ids[i], "agents") == 0) continue;   // RAM-only skip -- see flag comment below
#endif
    MODULES[COUNT] = m;
    snprintf(s_active_ids[COUNT], PAGE_ID_LEN, "%s", resolved.ids[i]);
    snprintf(s_active_opts[COUNT], PAGE_OPTS_LEN, "%s", resolved.opts[i]);
    COUNT++;
  }
}

// On-hardware automated substitute for the manual half of plan §8 criterion 3 (the Agents-page-hidden
// precondition for Home's prompt takeover): WS-4's bench session has no scripted way to drag the Agents
// page out of the active set in the hub's Settings window (that is real user configuration and stays
// human-hands, like every other page/complication drag -- see this plan section's header). This flag
// instead drops "agents" from the in-RAM MODULES[]/COUNT this boot builds screens from, AFTER the normal
// NVS-backed resolve above -- it never calls nvs_set_bytes, so the persisted "pages" NVS key some real
// hub configured is untouched and a normal `-e beacon` boot (flag undefined => this block compiles out)
// sees the user's actual list again. Paired with dev_seed.cpp's BEACON_CAP_BUDDY=1 (also RAM-only, also
// restores on a normal reboot) to seed a present prompt without a real Claude Code hook round-trip.

// Headroom above COMP_CATALOG_N (8 today: clock/fin/ice/agents/usage/weather/sonos/chart) -- generous
// enough that a future catalog addition does not need this bumped, but COMP_CATALOG_N is an extern
// runtime value (defined in complications.cpp) so it cannot size a compile-time array itself here.
#define COMP_KNOWN_CAP 16

// Build the "this firmware can actually render" arrays comp_list_resolve needs: walk COMP_CATALOG (the
// ONE home of size/takes_arg -- plan §13 item 1) and keep only the ids this build has a renderer for
// (comp_find() non-NULL). "chart" is in the catalog with no renderer yet (Phase 2), so it is correctly
// absent from `known` and any placement naming it is dropped by comp_list_resolve's rule 1.
static uint8_t known_comps(const char* known[COMP_KNOWN_CAP], uint8_t known_size[COMP_KNOWN_CAP]) {
  uint8_t n = 0;
  for (uint8_t i = 0; i < COMP_CATALOG_N && n < COMP_KNOWN_CAP; i++) {
    if (!comp_find(COMP_CATALOG[i].id)) continue;
    known[n] = COMP_CATALOG[i].id;
    known_size[n] = COMP_CATALOG[i].size;
    n++;
  }
  return n;
}

// Only "home" exists today (comp_state.cpp's COMP_FACES has one entry) -- looked up by id rather than
// assumed at index 0 so a second face slots in later with no change here.
static const comp_face_t* home_face(void) {
  for (uint8_t i = 0; i < COMP_FACES_N; i++)
    if (strcmp(COMP_FACES[i].id, "home") == 0) return &COMP_FACES[i];
  return nullptr;
}

// Resolve the persisted (or compiled-default) complication assignment into comp_state's ACTIVE list.
// Must run before any page is built (mirrors load_active_pages() -- home_editorial.cpp's build() reads
// comp_state_active() via comp_stack_build()).
static void load_active_comps(void) {
  const comp_face_t* face = home_face();
  if (!face) return;   // no "home" face compiled in; should not happen

  const char* known[COMP_KNOWN_CAP]; uint8_t known_size[COMP_KNOWN_CAP];
  uint8_t known_n = known_comps(known, known_size);

  char stored[COMP_SLOTS_MAX * COMP_ENTRY_LEN] = {0};
  size_t n = nvs_get_bytes(face->nvs_key, stored, sizeof(stored) - 1);
  stored[n < sizeof(stored) ? n : sizeof(stored) - 1] = '\0';
  if (n == 0) snprintf(stored, sizeof(stored), "%s", face->default_slots);

  comp_list_t want, fallback, resolved;
  comp_list_deserialize(stored, &want);
  comp_list_deserialize(face->default_slots, &fallback);
  // Boot never carries an explicit-empty signal (that only arrives on the wire): an NVS blob that
  // resolves to nothing falls back to the compiled default, same as an all-unknown wire request would.
  comp_list_resolve(&want, known, known_size, known_n, face->slots, false, &fallback, &resolved);
  comp_state_set_active(&resolved);
}

static lv_obj_t* s_pager = nullptr;
static lv_obj_t* s_pages[8];
static lv_obj_t* s_dots[8];
static int s_current = 0;
static bool s_settling = false;   // guards reentrant SCROLL_END from our own recenter()
static lv_timer_t* s_tick = nullptr;   // the 500ms visible-screen update timer; paused while idle (#60)

static void set_dots(int active) {
  const beacon_theme_t* t = theme_active();
  for (int i = 0; i < COUNT; i++)
    lv_obj_set_style_bg_color(s_dots[i], i == active ? t->accent : t->line, 0);
}

static void show(int idx) {
  s_current = idx;
  set_dots(idx);
  if (MODULES[idx]->update) MODULES[idx]->update();
  nvs_set_screen((uint8_t)idx);   // persist last screen (FR-PLAT-3)
}

// Theme hook: per-theme LAYOUTS differ, so a theme switch rebuilds every page (clear + chrome +
// the new theme's view), not just a restyle. Cheap enough with the LVGL pool in PSRAM.
static void on_theme(const beacon_theme_t* t) {
  styles_rebuild(t);
  for (int i = 0; i < COUNT; i++) {
    lv_obj_clean(s_pages[i]);
    chrome_attach(s_pages[i]);
    MODULES[i]->build(s_pages[i]);
    // Populate every page now so a freshly-built label never shows LVGL's default "Text"
    // when it scrolls into view before its first tick. Off-screen invalidations are clipped.
    if (MODULES[i]->update) MODULES[i]->update();
  }
  set_dots(s_current);
}

// Reorder the page objects so s_current sits at the center slot with its circular neighbours
// on both sides, then pin the scroll to that slot without animation. The page under the
// viewport is unchanged pixels, so the rearrange is invisible -- it just guarantees a real
// neighbour exists in both directions for the next swipe, making the wrap boundary an ordinary
// one-page move (FR fix #5). LV_OBJ_FLAG_SCROLL_ONE caps a gesture at one page, so neighbours
// on each side are always sufficient.
static void recenter(void) {
  s_settling = true;   // scroll_to_x(LV_ANIM_OFF) re-emits SCROLL_END synchronously
  for (int slot = 0; slot < COUNT; slot++)
    lv_obj_move_to_index(s_pages[carousel_logical_at(s_current, slot, COUNT)], slot);
  lv_obj_update_layout(s_pager);
  lv_obj_scroll_to_x(s_pager, carousel_center_slot(COUNT) * SCREEN_W, LV_ANIM_OFF);
  s_settling = false;
}

static void scrollend_cb(lv_event_t*) {
  if (s_settling) return;
  int slot = carousel_index_for_x(lv_obj_get_scroll_x(s_pager), SCREEN_W, COUNT);
  if (slot == carousel_center_slot(COUNT)) return;   // bounced back to center: no page change
  show(carousel_logical_at(s_current, slot, COUNT));
  recenter();                                        // re-pin so the next swipe has both neighbours
}

static void tick_cb(lv_timer_t*) {
  // Live complication rebuild (plan §4/§8): LVGL-thread only, gated on !s_settling, no-op on an
  // identical list -- the three guards that make lv_obj_clean-from-a-timer safe. Runs regardless of
  // which page is current: Home's stack objects persist as carousel siblings even when scrolled away,
  // so applying while Home isn't visible is not merely safe but the common case.
  if (!s_settling) comp_stack_apply();
  if (MODULES[s_current]->update) MODULES[s_current]->update();
  set_dots(s_current);
}

// --- auto-rotate (FR-SET: unattended page cycling) ---
//
// Advances one page on a user-configurable interval so the device reads as an ambient display when
// nobody is touching it. Two guards keep it from fighting the user or the power budget:
//   1. Recent touch defers it. lv_disp_get_inactive_time() is the same activity clock the dim/sleep
//      logic uses, so a rotation never lands mid-gesture or yanks the page you just swiped to.
//   2. Dim/asleep suppresses it, because rotating an unlit panel burns QSPI flushes for nothing --
//      and #60 pauses the update tick there anyway, so a rotated page would arrive unpopulated.
static lv_timer_t* s_rotate = nullptr;
static uint32_t    s_rotate_due = 0;      // lv_tick_get() deadline for the next advance; 0 = unarmed
#define ROTATE_TOUCH_GRACE_MS 3000u       // a touch this recent restarts the dwell

static void rotate_cb(lv_timer_t*) {
  uint32_t period = DURATIONS[nvs_get_byte(NVS_ROTATE_KEY, ROTATE_DEFAULT_IDX)].ms;
  if (period == 0) { s_rotate_due = 0; return; }   // "Never" => off (timer stays armed but inert)
  // Stop only when the panel is actually OFF. Dim still shows content, so an ambient rotation should
  // keep going there -- gating on idle_is_inactive() meant any interval >= the dim timeout (default
  // 1 min) never fired at all, which is why this looked completely dead.
  if (idle_is_asleep()) { s_rotate_due = 0; return; }

  uint32_t now = lv_tick_get();
  // A recent touch restarts the dwell, so the page you just swiped to gets a full interval and a
  // rotation never lands mid-gesture.
  if (lv_disp_get_inactive_time(NULL) < ROTATE_TOUCH_GRACE_MS) { s_rotate_due = now + period; return; }
  if (s_rotate_due == 0) { s_rotate_due = now + period; return; }   // arm on the first eligible tick
  if ((int32_t)(now - s_rotate_due) < 0) return;                    // signed compare: tick wraps at 2^32

  s_rotate_due = now + period;   // own deadline, NOT the inactivity clock: reusing inactivity meant
                                 // every poll past the threshold fired, rotating at the poll rate.
  LOGI("rotate: advancing from screen %d (every %ums)", s_current, (unsigned)period);
  lv_obj_scroll_by(s_pager, -SCREEN_W, 0, LV_ANIM_ON);   // same path a swipe takes (SCROLL_END -> show)
}

// Advance one page in either direction (+1 next, -1 prev). Same scroll path a swipe takes, so
// SCROLL_END -> show() -> recenter() all run normally. Also pushes the auto-rotate dwell out, so a
// deliberate button press is not immediately overridden by a rotation that was already due.
void carousel_advance(int dir) {
  if (dir == 0) return;
  lv_disp_trig_activity(NULL);   // count as user activity: wake, and restart dim/sleep + rotate dwell
  lv_obj_scroll_by(s_pager, dir > 0 ? -SCREEN_W : SCREEN_W, 0, LV_ANIM_ON);
}

// Re-arm after a settings change so a new interval takes effect without a reboot. Polls at a fraction
// of the interval so the touch-grace check is re-evaluated often enough to be responsive, while the
// actual advance is paced by s_rotate_due.
void carousel_apply_rotate(void) {
  uint32_t period = DURATIONS[nvs_get_byte(NVS_ROTATE_KEY, ROTATE_DEFAULT_IDX)].ms;
  uint32_t poll = period ? (period / 4 < 1000 ? 1000 : period / 4) : 5000;
  s_rotate_due = period ? lv_tick_get() + period : 0;   // full dwell from the moment it was set
  if (!s_rotate) s_rotate = lv_timer_create(rotate_cb, poll, NULL);
  else           lv_timer_set_period(s_rotate, poll);
}

#if BEACON_PERF
// Deterministic swipe benchmark (BEACON_PERF only). Animating a one-page scroll on a timer drives the
// EXACT render path a finger does -- scroll animation, SCROLL_END, show(), recenter() -- so the
// `perf:` numbers are reproducible and comparable across builds instead of depending on how fast
// somebody happened to swipe during a capture window. Also keeps the panel awake so the idle pause
// (#60) can't silently halve the sample.
static void autoswipe_cb(lv_timer_t*) {
  lv_disp_trig_activity(NULL);
  lv_obj_scroll_by(s_pager, -SCREEN_W, 0, LV_ANIM_ON);
}
#endif

#if BEACON_COMPS_STRESS
// On-hardware automated substitute for the manual half of the plan §8 exit gate ("drag-save 20x while
// continuously swiping the carousel, deliberately trying to land an apply inside a scroll animation and
// inside the s_settling recenter window"). WS-4's bench session cannot script a finger dragging inside
// the hub's Settings window or physically swiping the device -- but the RISK that stress is checking for
// (lv_obj_clean firing from the tick timer while a scroll animation or the s_settling recenter is in
// flight) has nothing to do with where the "comps" value came from. This calls carousel_apply_comps()
// -- the EXACT function hub_task.cpp's on_comps() calls for a real hub push, including the NVS
// persist-before-apply -- on a timer faster than tick_cb's 500ms, alternating between two different
// valid 6-slot assignments so every firing is a real change. Paired with BEACON_PERF's autoswipe (both
// flags are set together in env:compstress), applies land while the pager is mid-scroll-animation and
// inside scrollend_cb's s_settling window essentially every cycle -- no finger required. NOT shipped;
// env:beacon is byte-for-byte unaffected (this whole block compiles out when the flag is unset).
static bool s_stress_toggle = false;
static void compstress_cb(lv_timer_t*) {
  comp_list_t want;
  comp_list_deserialize(s_stress_toggle ? "clock,fin.sp500,ice,agents"
                                        : "clock,usage.codex,weather,sonos", &want);
  s_stress_toggle = !s_stress_toggle;
  bool changed = false;
  uint8_t n = carousel_apply_comps(&want, false, &changed);
  LOGI("compstress: requested toggle=%d -> %u placements resolved, changed=%d",
       (int)!s_stress_toggle, (unsigned)n, changed);
}
#endif

void carousel_init(void) {
  load_active_pages();   // MODULES/COUNT are runtime state now; resolve before any page is created.
  load_active_comps();   // comp_state's active list; resolve before Home's build() reads it.
#if BEACON_RESTORE_DEFAULT_COMPS
  // One-shot bench cleanup (WS-4, not shipped): writes NVS "c_home" back to the compiled default,
  // undoing env:compstress's real (by design) carousel_apply_comps() writes from the live-rebuild
  // stress run. Flash once, confirm, then flash back to a flag-free env:beacon build.
  { const comp_face_t* f = home_face(); if (f) {
      comp_list_t def; comp_list_deserialize(f->default_slots, &def);
      bool changed = false; carousel_apply_comps(&def, false, &changed);
      LOGI("restore: c_home reset to default (changed=%d)", changed);
  } }
#endif
  lv_obj_set_style_bg_color(lv_scr_act(), lv_color_black(), 0);
  lv_obj_set_style_bg_opa(lv_scr_act(), LV_OPA_COVER, 0);

  s_pager = lv_obj_create(lv_scr_act());
  lv_obj_remove_style_all(s_pager);
  lv_obj_set_size(s_pager, SCREEN_W, SCREEN_H);
  lv_obj_add_style(s_pager, &S.screen, 0);
  lv_obj_set_flex_flow(s_pager, LV_FLEX_FLOW_ROW);
  lv_obj_set_scroll_dir(s_pager, LV_DIR_HOR);
  lv_obj_set_scroll_snap_x(s_pager, LV_SCROLL_SNAP_CENTER);
  lv_obj_add_flag(s_pager, LV_OBJ_FLAG_SCROLL_ONE);
  lv_obj_set_scrollbar_mode(s_pager, LV_SCROLLBAR_MODE_OFF);
  lv_obj_set_style_pad_all(s_pager, 0, 0);
  lv_obj_set_style_pad_column(s_pager, 0, 0);
  lv_obj_add_event_cb(s_pager, scrollend_cb, LV_EVENT_SCROLL_END, NULL);

  for (int i = 0; i < COUNT; i++) {
    lv_obj_t* page = lv_obj_create(s_pager);
    lv_obj_remove_style_all(page);
    lv_obj_set_size(page, SCREEN_W, SCREEN_H);
    lv_obj_add_flag(page, LV_OBJ_FLAG_SNAPPABLE);
    lv_obj_clear_flag(page, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_style_pad_all(page, 0, 0);
    s_pages[i] = page;   // content built by on_theme() below
  }

  // Dot indicator on the top layer (does not scroll with pages), bottom arc-free band.
  lv_obj_t* bar = lv_obj_create(lv_layer_top());
  lv_obj_remove_style_all(bar);
  lv_obj_set_flex_flow(bar, LV_FLEX_FLOW_ROW);
  lv_obj_set_style_pad_column(bar, 8, 0);
  lv_obj_set_size(bar, LV_SIZE_CONTENT, LV_SIZE_CONTENT);
  lv_obj_align(bar, LV_ALIGN_BOTTOM_MID, 0, -(SAFE_INSET - 22));
  lv_obj_clear_flag(bar, LV_OBJ_FLAG_CLICKABLE);
  for (int i = 0; i < COUNT; i++) {
    lv_obj_t* d = lv_obj_create(bar);
    lv_obj_remove_style_all(d);
    lv_obj_set_size(d, 6, 6);
    lv_obj_set_style_radius(d, 3, 0);
    lv_obj_set_style_bg_opa(d, LV_OPA_COVER, 0);
    s_dots[i] = d;
  }

  theme_on_apply(on_theme);
  // One-time: apply the compiled default theme when it changes (THEME_DEFAULT_VER bump), without
  // stomping a later manual choice (that updates the theme but leaves the version satisfied).
  if (nvs_get_byte("thmver", 0) < THEME_DEFAULT_VER) {
    nvs_set_theme(DEFAULT_THEME_INDEX);
    nvs_set_byte("thmver", THEME_DEFAULT_VER);
  }
  uint8_t theme0 = nvs_get_theme(DEFAULT_THEME_INDEX); if (theme0 >= THEME_COUNT) theme0 = DEFAULT_THEME_INDEX;
  theme_set(theme0);        // restore persisted theme; builds all pages via on_theme

  int start = nvs_get_screen(0); if (start >= COUNT) start = 0;   // restore last screen
  s_current = start;
  recenter();                                                      // pin start to the center slot
  show(start);
  s_tick = lv_timer_create(tick_cb, 500, NULL);
  carousel_apply_rotate();   // arm auto-rotate from the persisted interval
#if BEACON_PERF
  lv_timer_create(autoswipe_cb, 700, NULL);   // continuous scroll load; see autoswipe_cb
#endif
#if BEACON_COMPS_STRESS
  lv_timer_create(compstress_cb, 300, NULL);   // faster than tick_cb's 500ms; see compstress_cb
#endif
}

// #60: pause the per-tick repaint while the panel is dim/asleep so the display can actually sleep
// (no update() => no LVGL invalidations => no QSPI flushes). Resume runs one immediate update() so a
// wake shows current data with no up-to-500ms lag.
void carousel_set_tick_paused(bool paused) {
  if (!s_tick) return;
  if (paused) { lv_timer_pause(s_tick); return; }
  lv_timer_resume(s_tick);
  if (MODULES[s_current]->update) MODULES[s_current]->update();
}

int carousel_current(void) { return s_current; }
lv_obj_t* carousel_root(void) { return s_pager; }

// Buddy screen index in MODULES (home=0, finance=1, chart=2, ice=3, buddy=4, settings=5).
// Kept as a named function rather than carousel_goto(3) so callers don't embed the magic index.
// Index of a page in the ACTIVE list, or -1. Looked up by id: the old #define BUDDY_INDEX was wrong or
// moved four times as screens came and went, and with a hub-configurable list a constant cannot work.
static int active_index_of(const char* id) {
  for (int i = 0; i < COUNT; i++)
    if (strcmp(s_active_ids[i], id) == 0) return i;
  return -1;
}

bool carousel_has_page(const char* id) { return active_index_of(id) >= 0; }

bool carousel_page_opt(const char* page_id, const char* key, char* out, size_t cap) {
  if (out && cap) out[0] = '\0';
  if (!page_id || !key) return false;
  for (int i = 0; i < COUNT; i++)
    if (strcmp(s_active_ids[i], page_id) == 0)
      return page_opts_get(s_active_opts[i], key, out, cap);
  return false;
}

void carousel_goto_buddy(void) {
  int idx = active_index_of("agents");
  if (idx < 0) idx = active_index_of("home");   // Agents hidden: Home's prompt takeover covers it
  if (idx < 0) return;                          // neither exists: nothing to wake to
  if (s_current == idx) return;                 // already there; no scroll churn
  show(idx);
  recenter();
}

// Apply a page list from the hub. Persists first, so the choice survives even if the rebuild path
// fails, then restarts: rebuilding the pager's children live would have to tear down and recreate LVGL
// objects underneath a running render loop, and a page-set change is rare enough that ~5 s of reboot is
// the cheaper, safer trade. Returns the resolved page count (0 => nothing applied).
uint8_t carousel_apply_pages(const page_list_t* want, bool* changed) {
  if (changed) *changed = false;
  if (!want) return 0;
  const char* known[REGISTRY_N];
  for (uint8_t i = 0; i < REGISTRY_N; i++) known[i] = REGISTRY[i].id;

  page_list_t fallback, resolved;
  page_list_deserialize(DEFAULT_PAGES, &fallback);
  uint8_t n = page_list_resolve(want, known, REGISTRY_N, PAGE_ALWAYS_ID, &fallback, &resolved);
  if (n == 0) return 0;

  // Idempotence: the hub re-pushes the current config on every reconnect, so applying an identical list
  // must be a no-op. Without this the restart below reconnects, which re-pushes, which restarts again.
  page_list_t active; memset(&active, 0, sizeof(active));
  active.count = (uint8_t)COUNT;
  for (int i = 0; i < COUNT; i++) {
    snprintf(active.ids[i],  PAGE_ID_LEN,   "%s", s_active_ids[i]);
    snprintf(active.opts[i], PAGE_OPTS_LEN, "%s", s_active_opts[i]);
  }
  if (page_list_equal(&resolved, &active)) return n;   // changed stays false => caller must not restart

  char buf[PAGES_MAX * (PAGE_ID_LEN + PAGE_OPTS_LEN)];
  size_t len = page_list_serialize(&resolved, buf, sizeof(buf));
  if (len == 0) return 0;
  nvs_set_bytes(NVS_PAGES_KEY, buf, len);
  nvs_set_screen(0);   // the old index may not exist in the new list
  if (changed) *changed = true;
  return n;
}

// Apply a hub-supplied complication assignment for the "home" face. Unlike carousel_apply_pages, this
// never restarts: comp_state_set_pending() only queues the change, and comp_stack_apply() (called from
// tick_cb, LVGL thread, gated on !s_settling) rebuilds Home live within one 500 ms tick (plan §4/§8).
// Persist BEFORE queuing, so the choice survives NVS-adjacent even if the live-apply path somehow never
// runs (e.g. Home is never built this boot).
uint8_t carousel_apply_comps(const comp_list_t* want, bool explicit_empty, bool* changed) {
  if (changed) *changed = false;
  if (!want) return 0;

  const comp_face_t* face = home_face();
  if (!face) return 0;

  const char* known[COMP_KNOWN_CAP]; uint8_t known_size[COMP_KNOWN_CAP];
  uint8_t known_n = known_comps(known, known_size);

  comp_list_t fallback, resolved;
  comp_list_deserialize(face->default_slots, &fallback);
  uint8_t n = comp_list_resolve(want, known, known_size, known_n, face->slots,
                                explicit_empty, &fallback, &resolved);

  // Idempotence: the hub re-pushes the current assignment on every reconnect (design §7); applying an
  // identical list must be a no-op so a live rebuild never fires needlessly.
  comp_list_t active;
  comp_state_active(&active);
  if (comp_list_equal(&resolved, &active)) return n;   // changed stays false => caller must not queue

  char buf[COMP_SLOTS_MAX * COMP_ENTRY_LEN];
  size_t len = comp_list_serialize(&resolved, buf, sizeof(buf));
  // Persist BEFORE applying: the choice survives even if the rebuild path fails (plan §4 item 6).
  // nvs_set_bytes returns false on write failure and callers MUST check it (unlike the byte setters).
  if (!nvs_set_bytes(face->nvs_key, buf, len)) {
    LOGW("hub: comps nvs_set_bytes failed for key=%s", face->nvs_key);
    return n;   // resolved count still reported; nothing queued, so the old assignment keeps rendering
  }
  comp_state_set_pending(&resolved);
  if (changed) *changed = true;
  return n;
}

#if BEACON_CAPTURE
int carousel_count(void) { return COUNT; }
const char* carousel_screen_id(int idx) { return MODULES[idx]->id; }
void carousel_goto(int idx) { show(idx); recenter(); }   // same path scrollend_cb uses, sans gesture
#endif

void carousel_set_swipe_enabled(bool en) {
  if (en) { lv_obj_set_scroll_dir(s_pager, LV_DIR_HOR); lv_obj_add_flag(s_pager, LV_OBJ_FLAG_SCROLLABLE); }
  else    { lv_obj_clear_flag(s_pager, LV_OBJ_FLAG_SCROLLABLE); }
}
