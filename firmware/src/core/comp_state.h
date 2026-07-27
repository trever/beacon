#pragma once
#include "core/complications.h"

// The active/pending holder for the resolved Home complication assignment. Mutex-guarded, LVGL-free,
// host-linkable -- the same split DataStore uses for every cross-core record (core/datastore.h):
// "active" is what is currently BUILT on the LVGL thread (Core 1); "pending" is a hub-pushed change
// awaiting the next LVGL tick to apply it (Core 0 writes via comp_state_set_pending, Core 1 reads and
// clears via comp_state_take_pending). NVS and LVGL both live in the caller (ui/carousel.cpp, WS-1) --
// this file does neither, mirroring how core/page_config.cpp stays free of both.

// One host face's identity + defaults. Kept here (not in complications.h) because it names an NVS key,
// which is otherwise this file's caller's concern; grouping it with the state holder keeps the default
// string's one true home next to the code that seeds `active` from it at boot.
typedef struct {
  const char* id;             // "home"
  const char* nvs_key;        // "c_home" -- 6 chars, inside the 15-char NVS key limit
  const char* default_slots;  // "clock,fin.sp500,ice,agents" -- reproduces today's Home exactly
  uint8_t     slots;          // COMP_SLOTS_MAX
} comp_face_t;

extern const comp_face_t COMP_FACES[];
extern const uint8_t     COMP_FACES_N;

// Boot: seed from NVS (deserialized + resolved by the caller) or the compiled default.
void comp_state_set_active(const comp_list_t* l);

// By-value snapshot (DataStore discipline: callers get a copy, never a pointer into shared state).
bool comp_state_active(comp_list_t* out);

// Hub task (Core 0) writes a newly resolved assignment here; it does not take effect until the LVGL
// tick calls comp_state_take_pending (Core 1).
void comp_state_set_pending(const comp_list_t* l);

// LVGL tick (Core 1) reads-and-clears. Returns false (leaves *out untouched) when nothing is pending.
bool comp_state_take_pending(comp_list_t* out);

// One arg lookup against the ACTIVE assignment, mirroring carousel_page_opt(id, key, out, cap): false
// (and an empty `out`) when `id` is not currently placed, or is placed with no arg.
bool comp_arg(const char* id, char* out, size_t cap);
