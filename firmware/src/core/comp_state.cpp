#include "core/comp_state.h"
#include "core/ds_lock.h"
#include <string.h>
#include <stdio.h>

// Design §4.2 / plan §3 item 2: the default string has exactly one home. Only "home" exists today
// (a second face is deliberately unscheduled -- design §8); COMP_FACES_N stays 1 until one is added.
const comp_face_t COMP_FACES[] = {
  { "home", "c_home", "clock,fin.sp500,ice,agents", COMP_SLOTS_MAX },
};
const uint8_t COMP_FACES_N = sizeof(COMP_FACES) / sizeof(COMP_FACES[0]);

static comp_list_t s_active;
static comp_list_t s_pending;
static bool        s_pending_valid = false;
static ds_lock_t   s_lock;
static bool        s_lock_init = false;

// Lazy, one-shot init rather than a separate comp_state_init() entry point (there isn't one in the
// public API): comp_state_set_active() is always the first call, made once from carousel_init() before
// any task that could race it has started (mirrors how carousel_init() itself is single-threaded at
// boot). ds_lock_init is a no-op on the native test build (std::mutex needs none).
static void ensure_lock(void) {
  if (!s_lock_init) { ds_lock_init(s_lock); s_lock_init = true; }
}

void comp_state_set_active(const comp_list_t* l) {
  ensure_lock();
  ds_lock_take(s_lock);
  if (l) s_active = *l; else memset(&s_active, 0, sizeof(s_active));
  ds_lock_give(s_lock);
}

bool comp_state_active(comp_list_t* out) {
  if (!out) return false;
  ensure_lock();
  ds_lock_take(s_lock);
  *out = s_active;
  ds_lock_give(s_lock);
  return true;
}

void comp_state_set_pending(const comp_list_t* l) {
  ensure_lock();
  ds_lock_take(s_lock);
  if (l) s_pending = *l; else memset(&s_pending, 0, sizeof(s_pending));
  s_pending_valid = true;
  ds_lock_give(s_lock);
}

bool comp_state_take_pending(comp_list_t* out) {
  ensure_lock();
  ds_lock_take(s_lock);
  bool had = s_pending_valid;
  if (had && out) *out = s_pending;
  s_pending_valid = false;
  ds_lock_give(s_lock);
  return had;
}

bool comp_arg(const char* id, char* out, size_t cap) {
  if (out && cap) out[0] = '\0';
  if (!id || !*id) return false;
  ensure_lock();
  ds_lock_take(s_lock);
  bool found = false;
  for (uint8_t i = 0; i < s_active.count && i < COMP_SLOTS_MAX; i++) {
    if (strncmp(s_active.ids[i], id, COMP_ID_LEN) == 0) {
      if (out && cap) snprintf(out, cap, "%s", s_active.args[i]);
      found = s_active.args[i][0] != '\0';
      break;
    }
  }
  ds_lock_give(s_lock);
  return found;
}
