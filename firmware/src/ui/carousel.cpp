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
#include <string.h>
#include "util/log.h"
#include "config/layout.h"
#include "ui/screens/screen_home.h"
#include "ui/screens/screen_finance.h"
#include "ui/screens/screen_ice.h"
#include "ui/screens/screen_chart.h"
#include "ui/screens/screen_buddy.h"
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
    MODULES[COUNT] = m;
    snprintf(s_active_ids[COUNT], PAGE_ID_LEN, "%s", resolved.ids[i]);
    COUNT++;
  }
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

void carousel_init(void) {
  load_active_pages();   // MODULES/COUNT are runtime state now; resolve before any page is created.
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

void carousel_goto_buddy(void) {
  int idx = active_index_of("agents");
  if (idx < 0) return;                    // the user removed the agents page: nothing to wake to
  if (s_current == idx) return;           // already there; no scroll churn
  show(idx);
  recenter();
}

// Apply a page list from the hub. Persists first, so the choice survives even if the rebuild path
// fails, then restarts: rebuilding the pager's children live would have to tear down and recreate LVGL
// objects underneath a running render loop, and a page-set change is rare enough that ~5 s of reboot is
// the cheaper, safer trade. Returns the resolved page count (0 => nothing applied).
uint8_t carousel_apply_pages(const page_list_t* want) {
  if (!want) return 0;
  const char* known[REGISTRY_N];
  for (uint8_t i = 0; i < REGISTRY_N; i++) known[i] = REGISTRY[i].id;

  page_list_t fallback, resolved;
  page_list_deserialize(DEFAULT_PAGES, &fallback);
  uint8_t n = page_list_resolve(want, known, REGISTRY_N, PAGE_ALWAYS_ID, &fallback, &resolved);
  if (n == 0) return 0;

  char buf[PAGES_MAX * PAGE_ID_LEN];
  size_t len = page_list_serialize(&resolved, buf, sizeof(buf));
  if (len == 0) return 0;
  nvs_set_bytes(NVS_PAGES_KEY, buf, len);
  nvs_set_screen(0);   // the old index may not exist in the new list
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
